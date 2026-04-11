CRANE_DIR := crane
SDL2_BINDINGS_DIR := rocq-crane-sdl2
GAME_TREES_DIR := game-trees
BUILD_DIR := _build/ReversirocqGame
SRC_DIR   := src
GEN_DIR   := $(SRC_DIR)/generated
UNAME_S := $(shell uname -s)

ifeq ($(origin CXX), default)
  CXX := c++
endif
LDFLAGS :=

ifeq ($(UNAME_S),Darwin)
  BREW_LLVM := $(shell brew --prefix llvm 2>/dev/null)
  BREW_CLANG := $(BREW_LLVM)/bin/clang++
  ifneq ($(wildcard $(BREW_CLANG)),)
    CXX := $(BREW_CLANG)
    LDFLAGS := -L$(BREW_LLVM)/lib/c++ -Wl,-rpath,$(BREW_LLVM)/lib/c++
  endif
endif

IS_CLANG := $(shell $(CXX) --version 2>/dev/null | grep -qi clang && echo yes)
BRACKET_DEPTH_FLAG :=
ifeq ($(IS_CLANG),yes)
  BRACKET_DEPTH_FLAG := -fbracket-depth=1024
endif

SDL2_CFLAGS = $(shell pkg-config --cflags sdl2 SDL2_image SDL2_mixer)
SDL2_LIBS   = $(shell pkg-config --libs sdl2 SDL2_image SDL2_mixer)

CXXFLAGS = -std=c++23 $(BRACKET_DEPTH_FLAG) -I$(GEN_DIR) -I$(SDL2_BINDINGS_DIR)/src -I$(CRANE_DIR)/theories/cpp $(SDL2_CFLAGS)
OPT ?= -O2

.PHONY: all clean run extract check check-crane check-sdl-bindings prepare-sdl-bindings install-sdl-bindings

all: reversirocq

check-crane:
	@test -d $(CRANE_DIR)/theories/cpp || \
	  (echo "error: Crane not found at ./$(CRANE_DIR)"; \
	   echo "Run: git submodule update --init"; \
	   exit 1)

check-sdl-bindings:
	@test -d $(SDL2_BINDINGS_DIR)/theories || \
	  (echo "error: SDL2 bindings not found at ./$(SDL2_BINDINGS_DIR)"; \
	   echo "Run: git submodule update --init"; \
	   exit 1)

prepare-sdl-bindings: check-sdl-bindings
	@if [ -e $(SDL2_BINDINGS_DIR)/crane ]; then \
	  echo "Removing nested $(SDL2_BINDINGS_DIR)/crane checkout; reversirocq uses top-level ./crane"; \
	  rm -rf $(SDL2_BINDINGS_DIR)/crane; \
	fi

install-sdl-bindings: check-crane prepare-sdl-bindings
	cd $(SDL2_BINDINGS_DIR) && dune build -p rocq-crane-sdl2 @install && dune install -p rocq-crane-sdl2

extract: check-crane check-sdl-bindings install-sdl-bindings theories/Reversirocq.v
	dune clean
	dune build theories/Reversirocq.vo
	@mkdir -p $(GEN_DIR)
	cp $(BUILD_DIR)/reversirocq.h $(BUILD_DIR)/reversirocq.cpp $(GEN_DIR)/

check:
	$(MAKE) install-sdl-bindings
	dune build -p reversirocq

$(GEN_DIR)/reversirocq.cpp $(GEN_DIR)/reversirocq.h: theories/Reversirocq.v
	$(MAKE) extract

reversirocq: check-crane $(GEN_DIR)/reversirocq.cpp $(GEN_DIR)/reversirocq.h
	$(CXX) $(CXXFLAGS) $(OPT) $(LDFLAGS) $(GEN_DIR)/reversirocq.cpp $(SDL2_LIBS) -o reversirocq

clean:
	dune clean
	rm -rf reversirocq $(GEN_DIR) reversirocq.dSYM

run: reversirocq
	./reversirocq
