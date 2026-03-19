CC      = $(CROSS)gcc
CFLAGS  = -Wall -Wextra -O2 -static
SRC     = Src
INC     = Inc
BIN     = bin
TARGETS = $(BIN)/core_id $(BIN)/send_state

.PHONY: all clean

all: $(BIN) $(TARGETS)

$(BIN):
	mkdir -p $(BIN)

$(BIN)/core_id: $(SRC)/core_id.c
	$(CC) $(CFLAGS) -I$(INC) -o $@ $<

$(BIN)/send_state: $(SRC)/send_state.c
	$(CC) $(CFLAGS) -I$(INC) -o $@ $<

clean:
	rm -f $(TARGETS)
