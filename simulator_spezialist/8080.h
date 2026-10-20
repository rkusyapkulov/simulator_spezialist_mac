// 8080.h
#ifndef CPU_8080_H
#define CPU_8080_H

#include <stdint.h>
#include <stdbool.h>

// --- СТРУКТУРА ПРОЦЕССОРА INTEL 8080 (КР580ВМ80А) ---
typedef struct {
    uint8_t A, B, C, D, E, H, L;            // Основные регистры
    uint16_t PC, SP;                        // Регистр счетчика команд и указатель стека
    
    // Флаги процессора
    bool S, Z, AC, P, CY;                   // Sign, Zero, Auxiliary Carry, Parity, Carry
    bool EI;                                // Разрешение прерываний
    bool halted;                            // Состояние останова процессора (HLT)
    
    int cycles_until_interrupt;             // Счетчик тактов до генерации прерывания
    bool int_pending;                       // Флаг отложенного аппаратного прерывания
    
    // Порты КР580ВВ55 (ППА)
    uint8_t ppi0_pa, ppi0_pb, ppi0_pc, ppi0_ctrl;
    uint8_t ppi1_pa, ppi1_pb, ppi1_pc, ppi1_ctrl;
} CPU8080;

// --- ИНТЕРФЕЙС УПРАВЛЕНИЯ ПРОЦЕССОРОМ ---
void cpu8080_reset(CPU8080 *cpu);
int cpu8080_step(CPU8080 *cpu);
uint8_t cpu8080_read(CPU8080 *cpu, uint16_t addr);
void cpu8080_write(CPU8080 *cpu, uint16_t addr, uint8_t val);

#endif // CPU_8080_H

