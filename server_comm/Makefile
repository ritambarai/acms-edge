CC      = $(CROSS)gcc
CFLAGS  = -Wall -Wextra -O2 -static
SRC     = Src
INC     = Inc
BIN     = bin
TARGETS = $(BIN)/core_id $(BIN)/send_state $(BIN)/server_scheduler $(BIN)/state_wait

# state_wait durations (seconds)
WAIT_RUNNING = 30
WAIT_WAITING = 15
WAIT_FLAGS   = -DWAIT_RUNNING=$(WAIT_RUNNING) -DWAIT_WAITING=$(WAIT_WAITING)

.PHONY: all clean

all: $(BIN) $(TARGETS)

$(BIN):
	mkdir -p $(BIN)

$(BIN)/core_id: $(SRC)/core_id.c
	$(CC) $(CFLAGS) -I$(INC) -o $@ $<

$(BIN)/send_state: $(SRC)/send_state.c
	$(CC) $(CFLAGS) -I$(INC) -o $@ $<

$(BIN)/server_scheduler: $(SRC)/server_scheduler.c
	$(CC) $(CFLAGS) -I$(INC) -o $@ $<

$(BIN)/state_wait: $(SRC)/state_wait.c
	$(CC) $(CFLAGS) $(WAIT_FLAGS) -I$(INC) -o $@ $<

clean:
	rm -f $(TARGETS)
