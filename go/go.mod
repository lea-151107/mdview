module github.com/lea-151107/mdview/go

go 1.26.0

replace (
	github.com/lea-151107/dal => ../../dal
	github.com/lea-151107/dam => ../../dam
)

require (
	github.com/Shougo/goda.vim v0.7.2
	github.com/lea-151107/dal v0.0.0
	github.com/lea-151107/dam v0.0.0
	github.com/yuin/goldmark v1.8.7
	golang.org/x/image v0.47.0
)

require (
	golang.org/x/sys v0.49.0 // indirect
	golang.org/x/text v0.43.0 // indirect
)
