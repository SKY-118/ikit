install:
	swift build -c release
	cp .build/release/ikit ~/.local/bin/ikit
