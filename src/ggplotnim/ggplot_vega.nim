import json, tables, options, strutils, chroma, webview, sequtils
import ggplot_types, ggplot_styles, ggplot_theme, ggplot_scales, collect_and_fill
when defined(defaultBackend):
  import dataframe/fallback/formula
  import persvector
else:
  import dataframe/arraymancer_backend
import ginger except Scale

const vegaLiteTmpl = """
{
  "$schema": "https://vega.github.io/schema/vega-lite/v4.json",
  "description" : "Vega-lite plot created by ggplotnim"
}
"""

let mapping = { "title" : "title" }.toTable
let geom_mapping = { "point" : "point",
                     "rect" : "rect",
                     "line" : "line",
                     "histogram" : "bar",
                     "bar" : "bar",
                     "freqpoly" : "line",
                     "tile" : "rect",
                     "text" : "text",
                     "raster" : "rect", # or image?,
                     "errorbar" : "errorbar" # non trivial because they are split in vega
                   }.toTable

template toVegaField(f: string): string =
  # TODO: for some reason having `f` untyped and  using `astToStr`
  # on `f` does not work if `ggplot_types` is imported?!
  mapping[f]

iterator enumerateData(geom: FilledGeom): (Value, GgStyle, seq[GgStyle], DataFrame) =
  ## yields the pairs of continuous styles for the current discrete style and
  ## its data from `yieldData`
  for (label, tup) in pairs(geom.yieldData):
    yield (label, tup[0], tup[1], tup[2])

proc mapGeomKind(gk: GeomKind): string =
  result = geom_mapping[($gk).replace("gk", "").toLowerAscii]

proc toJson(v: Value): JsonNode =
  case v.kind
  of VString:
    result = % v.str
  of VInt:
    result = % v.num
  of VFloat:
    result = % v.fnum
  of VBool:
    result = % v.bval
  of VObject:
    result = % v.fields
  of VNull:
    result = newJNull()

proc vegaSanitize(s: string): string =
  ## NOTE: dots in field names for vega cause issues:
  ## https://github.com/vega/vega-lite/issues/6420
  ## The issue is that `.` apparently is a field access in vega
  result = s.multiReplace([(".", "_")])

proc getValidColName(s: Scale): string =
  result = s.getColName().vegaSanitize

proc dfToJson(df: DataFrame): JsonNode =
  result = newJArray()
  for row in df:
    var rowJson = newJObject()
    for k, v in row:
      rowJson[k.vegaSanitize] = v.toJson
    result.add rowJson

proc append(j: JsonNode, by: JsonNode) =
  doAssert j.kind == JArray
  doAssert by.kind == JArray
  for x in by:
    j.add x

proc dataAsJson(df: DataFrame): JsonNode =
  result = df.dfToJson

proc scaleKindToKey(scKind: ScaleKind, axKind: AxisKind): string =
  case scKind
  of scLinearData, scTransformedData:
    case axKind
    of akX: result = "x"
    of akY: result = "y"
  of scFillColor, scColor: result = "color"
  of scSize: result = "size"
  of scText: result = "text"
  else: echo "WARN: Losing information in `scaleKindToKey`"

proc encodeType(encoding: JsonNode, scKind: ScaleKind,
                axKind: AxisKind,
                dcKind: DiscreteKind,
                col: string,
                scale = (low: 0.0, high: 0.0)) =
  let key = scaleKindToKey(scKind, axKind)
  case dcKind
  of dcDiscrete:
    encoding[key] = %* { "field" : col,
                         "type" : "nominal" }
  of dcContinuous:
    encoding[key] = %* { "field" : col,
                         "type" : "quantitative" }
    if scale.low != scale.high:
      encoding[key]["scale"] = %* {"domain" : [scale.low, scale.high]}
  # now add possible scale specific things
  case scKind
  of scColor, scFillColor:
    if "scale" notin encoding[key]:
      encoding[key]["scale"] = newJObject()
    encoding[key]["scale"]["scheme"] = % "viridis"
  of scText:
    encoding[key]["format"] = % ".2f"
  else:
    echo "WARN: losing information in `encodeType`"
    discard

proc encodeGeomSpecifics(encoding: JsonNode, geom: Geom, df: DataFrame) =
  case geom.kind
  of gkHistogram:
    ## TODO: do not assume same bin width!
    let binWidth = df["binWidths", 0, float]
    encoding["x"]["bin"] = %* {"binned" : true, "step" : binWidth}
    encoding["x2"] = %* {"field" : "binEnd"}
    case geom.position
    of pkStack: discard
    of pkIdentity:
      encoding["y"]["stack"] = % nil
    else:
      echo "WARN: losing information in `encodeGeomSpecifics`!"
  of gkErrorBar:
    ## TODO: get min / max fields. `x` or `y` will be min and the other
    ## max will be `x2`, `y2` same as histogram binning
  else:
    echo "WARN: losing information in `encodeGeomSpecifics`!"

proc encodeStyle(encoding: JsonNode, style: GgStyle, col: string, dcKind: DiscreteKind) =
  if style.color.isSome:
    encoding.encodeType(scColor, akX, dcKind, col)
  if style.size.isSome:
    encoding.encodeType(scSize, akX, dcKind, col)

proc applyConfig(theme: Theme): JsonNode =
  result = %* { "background" : "#" & theme.getPlotBackground.fillColor.toHex,
                "axis" : {"gridColor" : "#FFFFFF" }
              }

proc genMark(fg: FilledGeom, style: Style): JsonNode =
  result = %* { "type" : mapGeomKind(fg.geomKind),
                "tooltip" : true,
                "opacity" : style.color.a
              }
  case fg.geomKind
  of gkPoint:
    result["color"] = % ("#" & style.color.toHex)
    result["filled"] = % true
  of gkLine, gkFreqPoly:
    result["color"] = % ("#" & style.color.toHex)
  of gkHistogram:
    result["color"] = % ("#" & style.fillColor.toHex)
  else:
    result["color"] = % ("#" & style.fillColor.toHex)

proc collectScales(filledScales: FilledScales, geom: Geom): seq[Scale] =
  for s in enumerateScalesVega(filledScales, geom):
    result.add s

proc toVegaLite*(p: GgPlot, filledScales: FilledScales, theme: Theme,
                 width, height: float): JsonNode =
  ## converts a `GgPlot` object to a vega-lite conform JsonNode
  # start with the template
  result = parseJson(vegaLiteTmpl)
  result[toVegaField("title")] = % p.title
  result["width"] = % width
  result["height"] = % height
  # iterate aes / scales here
  var layers = newJArray()
  let xScale = theme.xMarginRange
  let yScale = theme.yMarginRange
  var df = newDataFrame()
  ## `values` will store the dataframe. However, there will be duplicates in the current
  ## impl depending on multiple geoms with the same data!
  var values = newJArray()
  for fg in filledScales.geoms:
    df = newDataFrame()
    var encoding = newJObject()
    let x = $fg.xcol.vegaSanitize
    let y = $fg.ycol.vegaSanitize
    encoding.encodeType(scLinearData, akX, fg.dcKindX, x, xScale)
    encoding.encodeType(scLinearData, akY, fg.dcKindY, y, yScale)
    var colors: seq[string]
    var mark: JsonNode
    let scales = collectScales(filledScales, fg.geom)
    for (lab, baseStyle, styles, subDf) in enumerateData(fg):
      let style = mergeUserStyle(styles[0], fg.geom.userStyle, fg.geomKind)
      ## TODO: only add style if there is only one label (i.e. no discrete classification)
      mark = genMark(fg, style)

      encoding.encodeGeomSpecifics(fg.geom, subDf)
      for sc in scales:
        if styles.len == 1: # discrete
          for key, val in lab:
            if key.len > 0:
              colors.add ("#" & style.color.toHex)
            if sc.scKind notin {scLinearData, scTransformedData}:
              encoding.encodeType(sc.scKind, akX, dcDiscrete, sc.getValidColName())
        else:
          if sc.scKind notin {scLinearData, scTransformedData}:
            encoding.encodeType(sc.scKind, akX, dcContinuous, sc.getValidColName())
      case fg.geomKind
      of gkHistogram:
        let locDf = subDf.head(subDf.len - 1)
          .mutate(fn {"binEnd" ~ `displ` + `binWidths`})
        df.add locDf
      else:
        df.add subDf
    values.append df.dataAsJson
    if colors.len > 0 and "color" in encoding:
      encoding["color"]["scale"] = %* {"range" : colors.deduplicate}

    layers.add (%* { "mark" : mark, "encoding" : encoding })

  result["data"] = %* {"values" : values}
  result["layer"] = layers
  result["config"] = applyConfig(theme)


const indexHTML = """
<!doctype html>
<html>
  <head>
    <script src="https://cdn.jsdelivr.net/npm/vega@5"></script>
    <script src="https://cdn.jsdelivr.net/npm/vega-lite@4"></script>
    <script src="https://cdn.jsdelivr.net/npm/vega-embed@6"></script>
  </head>
  <body>
    <div id="vis"></div>
    <script type="text/javascript">
      vegaEmbed('#vis', $1).then(function(result) {{}}).catch(console.error);
    </script>
  </body>
</html>
"""
import os, strformat
proc showVega*(data: JsonNode, fname: string) =
  let outname = if fname.len == 0: &"{getTempDir()}/vega_lite_plot.html"
                else: getCurrentDir() / fname
  let content = indexHtml % [$data]
  writeFile(outname, content)
  var w = newWebView("Vega-Lite plot created by ggplotnim", "file://" & outname)
  w.run()
  w.exit()
  if fname.len == 0:
    defer: removeFile(outname)

from os import splitFile
proc ggvegaCreate*(p: GgPlot, vegaDraw: VegaDraw): JsonNode =
  var filledScales: FilledScales
  if p.ridges.isSome:
    # update all aesthetics to include the `yRidges` scale
    filledScales = collectScales(updateAesRidges(p))
  else:
    filledScales = collectScales(p)
  let theme = buildTheme(filledScales, p)
  result = p.toVegaLite(filledScales, theme, vegaDraw.width.get, vegaDraw.height.get)

proc `+`*(p: GgPlot, d: VegaDraw) =
  let plt = ggvegaCreate(p, d)
  let (_, fname, ext) = splitFile(d.fname)
  if ext == ".json":
    if d.asPrettyJson:
      writeFile(d.fname, pretty(plt))
    else:
      writeFile(d.fname, $plt)
  else:
    plt.showVega(d.fname)
