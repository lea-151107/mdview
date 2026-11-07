module mdview

go 1.26.0

replace (
	github.com/lea/dal => ../../dal
	github.com/lea/mermaid => ../../dam
)

require (
	github.com/Shougo/goda.vim v0.7.2
	github.com/lea/dal v0.0.0
	github.com/lea/mermaid v0.0.0
	golang.org/x/image v0.47.0
)

require (
	golang.org/x/sys v0.49.0 // indirect
	golang.org/x/text v0.43.0 // indirect
)
