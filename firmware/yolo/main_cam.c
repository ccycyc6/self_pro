#include "ares_soc.h"

extern int yolo_camera_run(void);

int main(void)
{
  uart_init(UART_DIV);

  printf("\n==================================================\n");
  printf("ARES-S1 camera detector / miniTensor INT8\n");
  printf("one ARES-L RV32IM core + one miniTensor + OV5640\n");
  printf("==================================================\n");

  return yolo_camera_run();
}
