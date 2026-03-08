# Typst concealer

A neovim plugin that uses the new(ish) kitty unicode rendering protocol to render typst expressions inline.
Has live previews as you type in insert mode.

Requires nvim >=11.0, and only works properly in ghostty and kitty.

Works in tmux (partially, it will break if two instances of the plugin work as they will replace each-other's images), will not work in zellij as they have no way of passing through the escape sequences kitty needs to display images.

Forked from [typst-concealer](https://www.github.com/PartyWumpus/typst-concealer), with love and efforts.

![example](./docs/example.png)

![example-1](./docs/example-1.png)

## Installation
Lazy.nvim:
```lua
return {
  "pxwg/typst-concealer",
  opts = {},
  ft = "typst",
}
```

### Keybinds
Typst-concealer can be disabled/enabled inside buffers. You can change the default with the `enabled_by_default` option.
```lua
-- example keybinds
vim.keymap.set("n", "<leader>ts", function()
  require("typst-concealer").enable_buf(vim.fn.bufnr())
end)
vim.keymap.set("n", "<leader>th", function()
  require("typst-concealer").disable_buf(vim.fn.bufnr())
end)
```

## Features
- (Maybe) highest resolution typst rendering in neovim community.
- More configurations aimed for multiple files projects.
- Live previews when in insert mode (WIP: does not support top level set/let/import)
- Supports top level set/let/import
- Renders code blocks
- Renders math blocks
- Can automatically match your nvim colorscheme

## Options
The options are mostly explained in the types, so either take a look in the code, (look for the `typstconfig` type) or get a good lua LSP and take a look what your autocomplete tells you.
The `styling_type` option is probably the most important one. It has three modes:
- "colorscheme" (default): Transparent background, and match the text color to your nvim colorscheme's color. This works reasonably well for most builtins, but many libraries aren't themed properly, or just look downright weird.
- "simple": Just remove the padding and get the width/height to fit of things to fit properly. Will have a white background, looking a little out of place in dark themes, but may be acceptable.
- "none": Do nothing, and completely rely on the user provided `#set`s. This is best for documents that never intend to be actually rendered as pdf/html, but just in neovim, otherwise the output of either neovim or the pdf is going to look rather strange.

These styles are applied *after* all other rules are applied.

## Known issues
- A temporary `.typst-concealer` file is created in the same directory as the file being edited, and is used for `typst watch`. This is a bit hacky, but it works. It will be deleted when the plugin is disabled, but if the plugin crashes or something, it may be left behind. You can safely delete it if it does.
- Breaks sometimes, pls report if any errors happen
- Sometimes the message sent to the kitty image protocol gets displayed on the screen as colourful garbage text. It's difficult to reproduce, and I have no idea what to do about this.

## Helpful tips

Sometimes, while rendering typst with some `#show` rules, for example:
```typ
#show conf.with(name: "test")
```
this plugin would crash since it breaks the preamble injection from the plugin. To fix this, you can do this hacky way to avoid this crash:
```typ
#let conf(name: "Title", doc) = {
  if concealed == "true" {
    doc
  } else {
    // place your actual theme/conf here
  }
}
```
and passing the `concealed` variable to `typst` in the configuration of the plugin:
```lua
require("typst-concealer").setup({
  -- other options...
  compile_args = {
    "--input",
    "concealed=true",
  },
})
```
Then the crash should be avoided, and you can still have your actual theme/conf when you render the pdf/html.

## TODO
- [ ] Support top level set/let/import when in live insert mode previews
- [ ] Automatically re-render a 'static' conceal when it is edited in insert mode
- [ ] Proper cleanup to get rid of dangling image ids
- [ ] Investigate weird rendering bug with transparency
- [ ] Write some better documentation. Investigate what the best way of doing it is.
