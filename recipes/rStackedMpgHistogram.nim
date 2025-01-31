import ggplotnim
let df = toDf(readCsv("data/mpg.csv"))
ggplot(df, aes("cty", fill = "class")) + 
  geom_histogram() + 
  theme_opaque() +
  ggsave("media/recipes/rStackedMpgHistogram.png")
