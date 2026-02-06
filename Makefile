CC      ?= cc
CFLAGS  ?= -Wall -Wextra -O2
LDFLAGS ?=

COMMON  = src/main.c src/convert.c

UNAME_S := $(shell uname -s)

ifeq ($(OS),Windows_NT)
    # Windows: DXGI Desktop Duplication capture + raw stdout output
    TARGET   = screen2cam.exe
    SRCS     = $(COMMON) src/capture_win.c src/vcam_win.c
    LIBS     = -ld3d11 -ldxgi -lole32
else ifeq ($(UNAME_S),Darwin)
    # macOS: ScreenCaptureKit capture + raw stdout output
    TARGET   = screen2cam
    SRCS     = $(COMMON) src/capture_mac.m src/vcam_mac.m
    LIBS     = -framework ScreenCaptureKit -framework CoreMedia \
               -framework CoreVideo -framework CoreGraphics -framework Foundation
    CFLAGS  += -fobjc-arc
else
    # Linux: X11 capture + V4L2 loopback output
    TARGET   = screen2cam
    SRCS     = $(COMMON) src/capture.c src/vcam.c
    LIBS     = -lX11 -lXext
endif

.PHONY: all clean

all: $(TARGET)

$(TARGET): $(SRCS)
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $(SRCS) $(LIBS)

clean:
	rm -f screen2cam screen2cam.exe
