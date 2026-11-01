#ifndef ARES_SOC_H
#define ARES_SOC_H

#ifndef UART_DIV
#define UART_DIV 8u
#endif

#include <stdint.h>

/* Simulation platform memory map (see rtl/common/ares_pkg.sv). */
#define UART_BASE       0xD0000000u
#define UART_TX         (UART_BASE + 0x00u)
#define UART_STATUS     (UART_BASE + 0x04u)
#define UART_CTRL       (UART_BASE + 0x08u)
#define UART_BAUD       (UART_BASE + 0x0Cu)

#define GPIO_BASE       0xD0001000u
#define GPIO_IN         (GPIO_BASE + 0x00u)
#define GPIO_OUT        (GPIO_BASE + 0x04u)
#define GPIO_DIR        (GPIO_BASE + 0x08u)

#define CLINT_BASE      0x00010000u
#define CLINT_MSIP(h)   (CLINT_BASE + 4u * (h))
#define CLINT_MTIMECMP(h) (CLINT_BASE + 0x4000u + 8u * (h))
#define CLINT_MTIME     (CLINT_BASE + 0xBFF8u)

#define SCRATCH_BASE    0x10000000u
#define MT_BASE         0xE0000000u

#define DDR_BASE        0x80000000u
#define DDR_UNC_BASE    0x40000000u

#define ARES_MMIO32(a)  (*(volatile uint32_t *)(uintptr_t)(a))
#define ARES_LED_ADDR   GPIO_OUT

static inline void ares_mmio_write(uint32_t addr, uint32_t value)
{
  *(volatile uint32_t *)(uintptr_t)addr = value;
}

static inline uint32_t ares_mmio_read(uint32_t addr)
{
  return *(volatile uint32_t *)(uintptr_t)addr;
}

static inline uint64_t ares_rd_mcycle64(void)
{
  uint32_t lo, hi, hi2;
  do {
    __asm__ volatile("csrr %0, 0xB80" : "=r"(hi));
    __asm__ volatile("csrr %0, 0xB00" : "=r"(lo));
    __asm__ volatile("csrr %0, 0xB80" : "=r"(hi2));
  } while (hi != hi2);
  return ((uint64_t)hi << 32) | lo;
}

static inline uint32_t ares_rd_mhartid(void)
{
  uint32_t v;
  __asm__ volatile("csrr %0, 0xF14" : "=r"(v));
  return v;
}

static inline void ares_fence(void) { __asm__ volatile("fence" ::: "memory"); }
static inline void ares_fence_i(void) { __asm__ volatile("fence.i" ::: "memory"); }

void uart_init(uint32_t baud_div);
void uart_putc(char c);
void uart_puts(const char *s);
int printf(const char *fmt, ...);
void halt(int code) __attribute__((noreturn));

#endif
