TARGET   := Kantan
APP      := $(TARGET).app
BIN      := $(APP)/Contents/MacOS/$(TARGET)
PLIST    := Info.plist
ICNS     := $(APP)/Contents/Resources/AppIcon.icns
SRCS     := $(shell find src -name '*.swift')
SWIFTC   := swiftc
SWIFTFLAGS := -O

.PHONY: all run clean

all: $(APP)

$(APP): $(BIN) $(APP)/Contents/Info.plist $(ICNS)

$(BIN): $(SRCS)
	@mkdir -p $(dir $@)
	$(SWIFTC) $(SWIFTFLAGS) -o $@ $(SRCS)

$(APP)/Contents/Info.plist: $(PLIST)
	@mkdir -p $(dir $@)
	cp $< $@

icon.png: make_icon.swift
	@mkdir -p build
	$(SWIFTC) make_icon.swift -o build/make_icon
	./build/make_icon $@

AppIcon.icns: icon.png
	rm -rf AppIcon.iconset
	mkdir -p AppIcon.iconset
	sips -z 16 16     icon.png --out AppIcon.iconset/icon_16x16.png
	sips -z 32 32     icon.png --out AppIcon.iconset/icon_16x16@2x.png
	sips -z 32 32     icon.png --out AppIcon.iconset/icon_32x32.png
	sips -z 64 64     icon.png --out AppIcon.iconset/icon_32x32@2x.png
	sips -z 128 128   icon.png --out AppIcon.iconset/icon_128x128.png
	sips -z 256 256   icon.png --out AppIcon.iconset/icon_128x128@2x.png
	sips -z 256 256   icon.png --out AppIcon.iconset/icon_256x256.png
	sips -z 512 512   icon.png --out AppIcon.iconset/icon_256x256@2x.png
	sips -z 512 512   icon.png --out AppIcon.iconset/icon_512x512.png
	cp icon.png       AppIcon.iconset/icon_512x512@2x.png
	iconutil -c icns AppIcon.iconset -o $@
	rm -rf AppIcon.iconset

$(ICNS): AppIcon.icns
	@mkdir -p $(dir $@)
	cp $< $@

run: $(APP)
	open $(APP)

clean:
	rm -rf $(APP) build icon.png AppIcon.icns AppIcon.iconset
