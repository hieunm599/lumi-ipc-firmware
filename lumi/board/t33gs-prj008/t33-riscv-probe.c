/* Read-only T33 PRJ008 MCU clock and controller inspection.
 * The vendor firmware archive's tx_isp_riscv_resource identifies MCU CCU
 * physical 0x12220000; tx_isp_riscv_stop sets control bit 31, and
 * tx_isp_riscv_run clears it after configuring its DDR boot vector.
 * 0x12700000 is the separate TNPU controller and is not accessed here.
 * No clock changes, SRAM writes, reset or boot operations are provided.
 */
#define _GNU_SOURCE
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#define BIT(n) (UINT32_C(1) << (n))
#define REG(p, off) ((p)[(off) / 4])
static volatile uint32_t *map_region(int fd, unsigned long addr)
{
    void *p = mmap(NULL, 4096, PROT_READ, MAP_SHARED, fd, addr);
    if (p == MAP_FAILED) { perror("mmap /dev/mem"); return NULL; }
    return p;
}

int main(int argc, char **argv)
{
    int fd, rc = 1;
    volatile uint32_t *cpm = NULL, *ccu = NULL;
    uint32_t gate, control;
    if (argc > 2 || (argc == 2 && strcmp(argv[1], "status"))) {
        fprintf(stderr, "Usage: %s [status]\n"
                "Read-only inspection of the T33 RISC-V MCU controller.\n"
                "Execution testing needs the vendor riscv_project SDK and "
                "a validated boot/memory ownership contract.\n", argv[0]);
        return 2;
    }
    fd = open("/dev/mem", O_RDONLY | O_SYNC);
    if (fd < 0) { perror("open /dev/mem"); return 1; }
    cpm = map_region(fd, 0x10000000);
    if (!cpm) goto out;
    gate = REG(cpm, 0x20);
    printf("CPM_CLKGR0=0x%08x RISC-V MCU gate=%s\n", gate,
           gate & BIT(22) ? "closed" : "open");
    printf("CPM_RISCV=0x%08x (raw; unchanged)\n", REG(cpm, 0x9c));
    if (gate & BIT(22)) {
        puts("MCU clock is gated; skipping its controller without changing clocks.");
        rc = 0; goto out;
    }
    ccu = map_region(fd, 0x12220000);
    if (!ccu) goto out;
    control = REG(ccu, 0xf0);
    printf("MCU_CCU_CONTROL[0x122200f0]=0x%08x SDK stop bit31=%u\n",
           control, !!(control & BIT(31)));
    printf("MCU_CCU_CONFIG[0x12220000]=0x%08x\n", REG(ccu, 0x00));
    printf("MCU_CCU_BOOT_VECTOR[0x12220004]=0x%08x\n", REG(ccu, 0x04));
    printf("MCU_CCU_IRQ_WORD[0x1222000c]=0x%08x\n", REG(ccu, 0x0c));
    puts("Register state alone does not prove instruction execution or wake-word support.");
    rc = 0;
out:
    if (ccu) munmap((void *)ccu, 4096);
    if (cpm) munmap((void *)cpm, 4096);
    close(fd);
    return rc;
}
