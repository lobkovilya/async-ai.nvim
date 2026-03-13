.PHONY: nvim

nvim:
	NVIM_APPNAME=nvim nvim -c "set runtimepath^=$(CURDIR)" -c "runtime plugin/async_ai.lua"
