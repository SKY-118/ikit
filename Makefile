INSTALL_PATH = ~/.local/bin
BINARY_NAME = ikit
BUILD_PATH = .build/release/$(BINARY_NAME)

all: build

build:
	swift build -c release

install: build
	mkdir -p $(INSTALL_PATH)
	cp $(BUILD_PATH) $(INSTALL_PATH)/$(BINARY_NAME)
	@echo "✅ Installed to $(INSTALL_PATH)/$(BINARY_NAME)"

clean:
	rm -rf .build

test:
	@echo "No tests available yet."
