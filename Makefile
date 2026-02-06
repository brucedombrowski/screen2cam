CC      ?= cc
CFLAGS  ?= -Wall -Wextra -O2
LDFLAGS ?=

TARGET  = screen2cam
COMMON  = src/main.c src/convert.c

UNAME_S := $(shell uname -s)

ifeq ($(UNAME_S),Darwin)
    # macOS: ScreenCaptureKit capture + raw stdout output
    SRCS     = $(COMMON) src/capture_mac.m src/vcam_mac.m
    LIBS     = -framework ScreenCaptureKit -framework CoreMedia \
               -framework CoreVideo -framework CoreGraphics -framework Foundation
    CFLAGS  += -fobjc-arc
else
    # Linux: X11 capture + V4L2 loopback output
    SRCS     = $(COMMON) src/capture.c src/vcam.c
    LIBS     = -lX11 -lXext
endif

.PHONY: all clean

all: $(TARGET)

$(TARGET): $(SRCS)
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $(SRCS) $(LIBS)

clean:
	rm -f $(TARGET)
