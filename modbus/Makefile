# Makefile for modbus_reader — Olimex Lime 2 (ARMv7)

CC     := arm-linux-gnueabihf-gcc
TARGET  = modbus_reader
SRC     = modbus_reader.c
HOST   ?= root@192.168.1.43

CFLAGS  = -Wall -Wextra -O2 -march=armv7-a -mfpu=neon-vfpv4 -mfloat-abi=hard
LDFLAGS =

.PHONY: all clean deploy

all: $(TARGET)

$(TARGET): $(SRC)
	$(CC) $(CFLAGS) -o $@ $^ $(LDFLAGS)

deploy: $(TARGET)
	scp $(TARGET) $(HOST):/usr/local/bin/

clean:
	rm -f $(TARGET)
