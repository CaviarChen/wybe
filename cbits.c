/* cbits
   $ clang -fPIC -shared cbits.c -o cbits.so
*/

#include <stdio.h>
#include <assert.h>
#include <gc.h>
#include <stdlib.h>
#include <stdint.h>
#include <math.h>

// putchard - putchar that takes a double and returns 0.
int print_int(int X) {
    return printf("%d", X);
}

int print_float(double X) {
    return printf("%f", X);
}

int print_string(const char *s) {
    return puts(s);
}

int read_char() {
    int ch;
    ch = getchar();
    return ch;        
}

int ipow(int base, int exp) {
    int result = 1;
    while (exp)
    {
        if (exp & 1)
            result *= base;
        exp >>= 1;
        base *= base;
    }

    return result;
}

int isqrt(int x) {
    double s;
    s = sqrt((double) x);
    return (int)s;
}


// Boehm GC
int wybe_malloc(int size) {
    GC_MALLOC(size);
    return size;
}

int gc_init(){
    GC_INIT();
    return 0;
}

