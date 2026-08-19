.PHONY: build test run clean

export DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer

build:
	./scripts/swift build

test:
	./scripts/swift test

run:
	./scripts/dev.sh

clean:
	rm -rf .build
