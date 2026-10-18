APP_NAME = Bosun
BUILD_DIR = .build
SCHEME = Bosun

.PHONY: generate build release clean

generate:
	xcodegen generate

build: generate
	xcodebuild -project $(APP_NAME).xcodeproj -scheme $(SCHEME) -configuration Release -derivedDataPath $(BUILD_DIR) build

release: build
	@echo "Создание DMG..."
	mkdir -p $(BUILD_DIR)/dmg
	cp -R "$(BUILD_DIR)/Build/Products/Release/$(APP_NAME).app" "$(BUILD_DIR)/dmg/"
	hdiutil create -volname "$(APP_NAME)" -srcfolder "$(BUILD_DIR)/dmg" -ov -format UDZO "$(BUILD_DIR)/$(APP_NAME).dmg"
	@echo "Готово: $(BUILD_DIR)/$(APP_NAME).dmg"

clean:
	rm -rf $(BUILD_DIR)
	rm -rf $(APP_NAME).xcodeproj
