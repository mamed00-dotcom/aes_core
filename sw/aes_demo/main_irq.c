// ===========================================================================
// main_irq.c - NEORV32 firmware: drive the AES coprocessor, IRQ-driven
// Project: AES-128 Core - real RISC-V integration (NEORV32)
// Author:  Mohammed Hajjar
//
// Same task as main.c, but instead of polling STATUS the CPU sleeps (WFI) and
// is woken by the coprocessor's interrupt, wired to the RISC-V machine-external
// interrupt (irq_mei_i). The trap handler drains the result FIFO - which also
// clears the (level-sensitive) interrupt - and sets a done flag.
//
// This exercises the full IRQ path that aes_coproc.v provides:
//   coproc result -> irq (level = IRQ_EN & ~out_empty) -> CPU MEI -> ISR -> POP
//
// FIPS-197 C.1 vector (same as main.c):
//   key = 000102030405060708090a0b0c0d0e0f
//   pt  = 00112233445566778899aabbccddeeff
//   ct  = 69c4e0d86a7b0430d8cdb78070b4c55a
// ===========================================================================

#include <stdint.h>

#define AES_BASE   0x90000000u
#define AES(off)   (*(volatile uint32_t *)(AES_BASE + (off)))

#define REG_CTRL   0x00u
#define REG_STATUS 0x04u
#define REG_IRQEN  0x08u
#define REG_KEY0   0x10u
#define REG_DIN0   0x20u
#define REG_DOUT0  0x30u

#define CTRL_PUSH      0x1u
#define CTRL_POP       0x2u
#define CTRL_KEY_LOAD  0x4u

#define ST_OUT_EMPTY  (1u << 3)
#define ST_KEY_READY  (1u << 4)

#define GPIO_OUT   (*(volatile uint32_t *)0xFFFC0004u)
#define SENTINEL_RUN   0x00000000u
#define SENTINEL_PASS  0x600DC0DEu
#define SENTINEL_FAIL  0xBAD00000u

// ---- minimal CSR access (no BSP dependency) -------------------------------
#define csr_write(csr, v) __asm__ volatile ("csrw " #csr ", %0" :: "r"(v))
#define csr_set(csr, v)   __asm__ volatile ("csrs " #csr ", %0" :: "r"(v))
#define csr_read(csr) ({ uint32_t __v; __asm__ volatile ("csrr %0, " #csr : "=r"(__v)); __v; })

#define MSTATUS_MIE   (1u << 3)    // global machine interrupt enable
#define MIE_MEIE      (1u << 11)   // machine external interrupt enable
#define MCAUSE_MEI    0x8000000bu  // interrupt bit | code 11 = machine external

// ---- shared between ISR and main ------------------------------------------
static volatile int      g_done = 0;
static volatile uint32_t g_ct[4];

// Machine-external interrupt handler. With mtvec in direct mode every trap
// vectors here; the only source we enable is the AES coprocessor. Draining a
// result deasserts the level-sensitive irq, so the handler self-clears.
void __attribute__((interrupt("machine"))) aes_isr(void)
{
    // mtvec is in direct mode, so every trap vectors here; only service the
    // machine-external interrupt (the coprocessor's irq). Anything else
    // (exception, other interrupt) is left alone rather than popping the FIFO.
    if (csr_read(mcause) != MCAUSE_MEI)
        return;
    if (AES(REG_STATUS) & ST_OUT_EMPTY)
        return;                       // nothing to read (spurious)
    g_ct[0] = AES(REG_DOUT0 + 0x0u);
    g_ct[1] = AES(REG_DOUT0 + 0x4u);
    g_ct[2] = AES(REG_DOUT0 + 0x8u);
    g_ct[3] = AES(REG_DOUT0 + 0xCu);
    AES(REG_CTRL) = CTRL_POP;         // free the slot -> out_empty -> irq clears
    g_done = 1;
}

int main(void)
{
    static const uint32_t key[4] = {
        0x00010203u, 0x04050607u, 0x08090a0bu, 0x0c0d0e0fu
    };
    static const uint32_t pt[4] = {
        0x00112233u, 0x44556677u, 0x8899aabbu, 0xccddeeffu
    };
    static const uint32_t ct_exp[4] = {
        0x69c4e0d8u, 0x6a7b0430u, 0xd8cdb780u, 0x70b4c55au
    };
    int i, ok;

    GPIO_OUT = SENTINEL_RUN;

    // program the key (one-time setup; polling here is fine and brief)
    for (i = 0; i < 4; i++)
        AES(REG_KEY0 + (uint32_t)(i << 2)) = key[i];
    AES(REG_CTRL) = CTRL_KEY_LOAD;
    while ((AES(REG_STATUS) & ST_KEY_READY) == 0u)
        ;

    // arm interrupts: coprocessor IRQ_EN, trap vector (direct mode), MEIE, MIE
    AES(REG_IRQEN) = 1u;
    csr_write(mtvec, (uint32_t)&aes_isr);   // low bits 0 => direct mode
    csr_set(mie,     MIE_MEIE);
    csr_set(mstatus, MSTATUS_MIE);

    // push one plaintext block, then sleep until the result interrupt arrives
    for (i = 0; i < 4; i++)
        AES(REG_DIN0 + (uint32_t)(i << 2)) = pt[i];
    AES(REG_CTRL) = CTRL_PUSH;

    while (!g_done)
        __asm__ volatile ("wfi");

    // check the ciphertext the ISR captured
    ok = 1;
    for (i = 0; i < 4; i++)
        if (g_ct[i] != ct_exp[i])
            ok = 0;

    GPIO_OUT = ok ? SENTINEL_PASS : SENTINEL_FAIL;

    for (;;)
        ;
    return 0;
}
