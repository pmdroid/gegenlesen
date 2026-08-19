.PHONY: build test run docs image clean

export DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer

build:
	./scripts/swift build

test:
	./scripts/swift test

run:
	./scripts/dev.sh

docs:
	cd www && npm run dev -- --host 0.0.0.0 --port 4321

image:
	./scripts/build-image.sh

clean:
	rm -rf .build
