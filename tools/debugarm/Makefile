CC=arm-linux-gnueabihf-gcc
#CFLAGS=-W -Wall -ansi -pedantic
CFLAGS=-O4
LDFLAGS=
EXEC=debug

all: $(EXEC) pcdump

debug: main.o serie.o disas.o lib.o command.o
	$(CC) -o $@ $^ $(LDFLAGS)

# Static: the MiSTer's C library is older than the cross toolchain's
pcdump: pcdump.o serie.o lib.o
	$(CC) -static -o $@ $^ $(LDFLAGS)

%.o: %.c
	$(CC) -o $@ -c $< $(CFLAGS)

main.o: lib.h
command.o: lib.h
disas.o: lib.h
serie.o: lib.h
lib.o: lib.h
pcdump.o: lib.h

clean:
	rm -rf *.o

