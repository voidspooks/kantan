TARGET   := Kantan
SRCS     := $(shell find . -name '*.swift' -not -path './.*')
SWIFTC   := swiftc
SWIFTFLAGS := -O

.PHONY: all run clean

all: $(TARGET)

$(TARGET): $(SRCS)
	$(SWIFTC) $(SWIFTFLAGS) -o $(TARGET) $(SRCS)

run: $(TARGET)
	./$(TARGET)

clean:
	rm -f $(TARGET)
