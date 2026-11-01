#include "ares_soc.h"
#include <stdarg.h>

void uart_putc_raw(char c);
#include <stddef.h>

#ifndef UART_DIV
#define UART_DIV 8u
#endif

void uart_init(uint32_t baud_div)
{
  ares_mmio_write(UART_CTRL, 0x3u);
  ares_mmio_write(UART_BAUD, baud_div);
}

void uart_putc_raw(char c)
{
  while ((ares_mmio_read(UART_STATUS) & 1u) == 0u) { }
  ares_mmio_write(UART_TX, (uint32_t)(uint8_t)c);
}

/* Bare LF on a Windows console moves down without returning to column zero, so
 * every line of output staircases.  Sending CR first fixes the terminal and is
 * what the boot code already does. */
void uart_putc(char c)
{
  if (c == '\n') uart_putc_raw('\r');
  uart_putc_raw(c);
}

void uart_puts(const char *s)
{
  while (*s) uart_putc(*s++);
}

static void print_uint(uint32_t v, uint32_t base, int upper, int width, char pad)
{
  char buf[16];
  int n = 0;
  const char *digits = upper ? "0123456789ABCDEF" : "0123456789abcdef";
  if (v == 0) buf[n++] = '0';
  while (v) {
    buf[n++] = digits[v % base];
    v /= base;
  }
  for (int i = n; i < width; i++) uart_putc(pad);
  while (n > 0) uart_putc(buf[--n]);
}

static void print_int(int32_t v, int width, char pad)
{
  if (v < 0) {
    uart_putc('-');
    print_uint((uint32_t)(-v), 10, 0, width > 0 ? width - 1 : 0, pad);
  } else {
    print_uint((uint32_t)v, 10, 0, width, pad);
  }
}

int printf(const char *fmt, ...)
{
  va_list ap;
  va_start(ap, fmt);
  while (*fmt) {
    if (*fmt != '%') {
      uart_putc(*fmt++);
      continue;
    }
    fmt++;
    int zero = 0, left = 0, width = 0;
    if (*fmt == '0') { zero = 1; fmt++; }
    if (*fmt == '-') { left = 1; fmt++; }
    while (*fmt >= '0' && *fmt <= '9') { width = width * 10 + (*fmt - '0'); fmt++; }
    int is_long = 0;
    if (*fmt == 'l') { is_long = 1; fmt++; if (*fmt == 'l') fmt++; }
    (void)is_long;
    char pad = zero ? '0' : ' ';
    switch (*fmt++) {
      case 'd':
      case 'i': print_int((int32_t)va_arg(ap, int), width, pad); break;
      case 'u': print_uint((uint32_t)va_arg(ap, unsigned int), 10, 0, width, pad); break;
      case 'x': print_uint((uint32_t)va_arg(ap, unsigned int), 16, 0, width, pad); break;
      case 'X': print_uint((uint32_t)va_arg(ap, unsigned int), 16, 1, width, pad); break;
      case 'p': uart_puts("0x"); print_uint((uint32_t)va_arg(ap, unsigned int), 16, 0, 8, '0'); break;
      case 'c': uart_putc((char)va_arg(ap, int)); break;
      case 's': {
        const char *s = va_arg(ap, const char *);
        if (!s) s = "(null)";
        if (left) { uart_puts(s); }
        else {
          int n = 0; const char *p = s;
          while (*p++) n++;
          for (int i = n; i < width; i++) uart_putc(' ');
          uart_puts(s);
        }
        break;
      }
      case 'f': {
        double d = va_arg(ap, double);
        int neg = d < 0.0;
        if (neg) { d = -d; uart_putc('-'); }
        uint32_t ip = (uint32_t)d;
        double frac_d = (d - (double)ip) * 1000.0;
        uint32_t frac = (uint32_t)(frac_d + 0.5);
        if (frac >= 1000u) { frac -= 1000u; ip += 1u; }
        print_uint(ip, 10, 0, 0, ' ');
        uart_putc('.');
        print_uint(frac, 10, 0, 3, '0');
        break;
      }
      case '%': uart_putc('%'); break;
      default: uart_putc('%'); uart_putc(fmt[-1]); break;
    }
  }
  va_end(ap);
  return 0;
}

void halt(int code)
{
  (void)code;
  for (;;) __asm__ volatile("ebreak");
}

void trap_handler(void) __attribute__((interrupt("machine"), aligned(4)));
void trap_handler(void)
{
  uint32_t cause, epc, tval;
  __asm__ volatile("csrr %0, mcause" : "=r"(cause));
  __asm__ volatile("csrr %0, mepc" : "=r"(epc));
  __asm__ volatile("csrr %0, mtval" : "=r"(tval));
  printf("\nTRAP cause=%08x epc=%08x tval=%08x\n", cause, epc, tval);
  halt(1);
}
void *memset(void *dst, int value, size_t n)
{
  unsigned char *p = (unsigned char *)dst;
  while (n--) *p++ = (unsigned char)value;
  return dst;
}

void *memcpy(void *dst, const void *src, size_t n)
{
  unsigned char *d = (unsigned char *)dst;
  const unsigned char *s = (const unsigned char *)src;
  while (n--) *d++ = *s++;
  return dst;
}

void *memmove(void *dst, const void *src, size_t n)
{
  unsigned char *d = (unsigned char *)dst;
  const unsigned char *s = (const unsigned char *)src;
  if (d < s) { while (n--) *d++ = *s++; }
  else { d += n; s += n; while (n--) *--d = *--s; }
  return dst;
}
