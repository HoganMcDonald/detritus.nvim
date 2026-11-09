local t = require("harness").t
local config = require("detritus.config")

describe("config", function()
  it("replaces key lists instead of merging them index-wise", function()
    local o = config.setup({ keys = { toggle = { "t" } } })
    t.eq(o.keys.toggle, { "t" })
    config.setup()
  end)

  it("keeps defaults for unspecified keys and allows disabling", function()
    local o = config.setup({ keys = { delete = false } })
    t.eq(o.keys.delete, false)
    t.eq(o.keys.goto_ref, "gd")
    config.setup()
  end)

  it("rejects unknown layouts", function()
    t.throws(function()
      config.setup({ layout = "bottom" })
    end, "layout")
    config.setup()
  end)

  it("defaults to the edgy layout", function()
    t.eq(config.setup().layout, "edgy")
  end)
end)
