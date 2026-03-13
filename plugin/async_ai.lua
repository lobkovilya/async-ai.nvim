if vim.g.loaded_async_ai_nvim == 1 then
  return
end

vim.g.loaded_async_ai_nvim = 1

require("async_ai").setup()
