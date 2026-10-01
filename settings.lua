data:extend({
  {
    type = "int-setting",
    name = "wide-splitters-max-width",
    setting_type = "startup",
    default_value = 10,
    minimum_value = 3,
    maximum_value = 256,
    order = "a",
  },
  {
    type = "string-setting",
    name = "wide-splitters-art-style",
    setting_type = "startup",
    default_value = "stretched",
    hidden=true,
    allowed_values = { "tiled", "stretched" },
    order = "a-b",
  },
  {
    type = "int-setting",
    name = "wide-splitters-balance-interval",
    setting_type = "runtime-global",
    default_value = 2,
    minimum_value = 1,
    maximum_value = 30,
    order = "b",
  },
})
