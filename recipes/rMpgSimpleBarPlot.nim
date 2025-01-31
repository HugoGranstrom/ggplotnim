import ggplotnim
let df = toDf(readCsv("data/mpg.csv"))
ggplot(df, aes("class")) + 
  geom_bar() + 
  theme_opaque() +
  ggsave("media/recipes/rMpgSimpleBarPlot.png")
