CC      ?= gcc
CFLAGS  ?= -Wall -Wextra -O2
LDFLAGS ?=

SRCS    = src/main.c src/capture.c src/vcam.c src/convert.c
TARGET  = screen2cam

LIBS    = -lX11 -lXext

.PHONY: all clean

all: $(TARGET)

$(TARGET): $(SRCS)
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $(SRCS) $(LIBS)

clean:
	rm -f $(TARGET)
