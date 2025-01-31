import ggplotnim
let df = toDf(readCsv("data/mpg.csv"))
let breaks = @[0'f64, 10, 15, 19, 23, 25, 40]
ggplot(df, aes("displ", "cty")) +
  geom_point(color = some(parseHex("F92672"))) +
  theme_opaque() +
  ggsave("media/recipes/rMpgCustomColorPoint.png")
