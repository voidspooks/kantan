TARGET   := Kantan
SRC      := Kantan.swift
SWIFTC   := swiftc
SWIFTFLAGS := -O

.PHONY: all run clean

all: $(TARGET)

$(TARGET): $(SRC)
	$(SWIFTC) $(SWIFTFLAGS) -o $(TARGET) $(SRC)

run: $(TARGET)
	./$(TARGET)

clean:
	rm -f $(TARGET)
