.PHONY: build test run docs clean

export DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer

build:
	./scripts/swift build

test:
	./scripts/swift test

run:
	./scripts/dev.sh

docs:
	cd www && npm run dev

clean:
	rm -rf .build
