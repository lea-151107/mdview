STATICCHECK_VERSION := 2026.2.2
GO_DIR := go

.PHONY: check fmt tidy vet staticcheck test test-go test-vim build

check: fmt tidy vet staticcheck test

fmt:
	@out=$$(cd $(GO_DIR) && gofmt -s -l .); if [ -n "$$out" ]; then echo "gofmt -s needed:"; echo "$$out"; exit 1; fi

# goda#build() (:MdviewBuild) runs "go mod tidy" in the clone of the users:
# it must change nothing there.
tidy:
	cd $(GO_DIR) && GOWORK=off go mod tidy -diff

vet:
	cd $(GO_DIR) && go vet ./...

staticcheck:
	cd $(GO_DIR) && go run honnef.co/go/tools/cmd/staticcheck@$(STATICCHECK_VERSION) ./...

test: test-go test-vim

test-go:
	cd $(GO_DIR) && CGO_ENABLED=0 go test ./...

test-vim:
	@if [ -d test ]; then vim -Nu NONE -i NONE -es -S test/run.vim; fi

# For development (g:mdview_bin): :MdviewBuild builds into a cache directory.
build:
	cd $(GO_DIR) && CGO_ENABLED=0 go build -o ../bin/mdview .
