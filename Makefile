.PHONY: build test run docs clean

export DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer

build:
	./scripts/swift build

test:
	./scripts/swift test

run:
	./scripts/dev.sh

docs:
	cd www && npm run dev -- --host 0.0.0.0 --port 4321

clean:
	rm -rf .build
