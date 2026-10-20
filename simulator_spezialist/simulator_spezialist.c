// simulator_spezialist.c
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdatomic.h>
#include "8080.h"
#include "simulator_spezialist.h"

#define CPU_CLOCK_HZ 2000000

// --- ГЛОБАЛЬНЫЕ БУФЕРЫ ПАМЯТИ ---
// Линейное адресное пространство компьютера "Специалист" (64 Кб)
static uint8_t spec_ram[65536];

// Физическая матрица: 6 строк (0..5), в каждой строке по 12 бит столбцов
// По умолчанию контакты разомкнуты (высокий уровень — 1), при нажатии биты сбрасываются в 0
uint16_t spec_key_matrix[6] = { 0xFFF, 0xFFF, 0xFFF, 0xFFF, 0xFFF, 0xFFF };
bool nr_button_pressed = false; // Клавиша НР (0 - нажата, 1 - отжата)

static uint32_t pixel_buffer[SCREEN_WIDTH * SCREEN_HEIGHT];

uint8_t spec_speaker_state = 0; 

// =========================================================================
// ИСПРАВЛЕННЫЙ АППАРАТНЫЙ ДИСПЕТЧЕР ЧТЕНИЯ ПАМЯТИ И ПОРТОВ
// =========================================================================
uint8_t cpu8080_read(CPU8080 *cpu, uint16_t addr) {
    // Дешифрация системного ППА №2 (Клавиатура/Звук: 0xF800-0xFFFF или зеркало 0xFF00-0xFF03)
    if ((addr >= 0xF800 && addr <= 0xFFFF) || (addr & 0xFFFC) == 0xFF00) {
        switch (addr & 3) {
        case 0: // --- ПОРТ А (Младшие 8 бит столбцов) ---
            if (cpu->ppi1_ctrl & 0x10) { // Если настроен на ввод
                uint8_t res = 0xFF;
                for (int r = 0; r < 6; r++) {
                    // Опрашиваем по маске процессора ИЛИ принудительно инжектируем, если кнопка нажата
                    if (!(cpu->ppi1_pb & (1 << (r + 2))) || spec_key_matrix[r] != 0xFFF) {
                        res &= (spec_key_matrix[r] & 0xFF);
                    }
                }
                return res;
            }
            return cpu->ppi1_pa;

        case 1: // --- ПОРТ В (Строки матрицы биты 2-7 + Кн. НР бит 1) ---
            if (cpu->ppi1_ctrl & 0x02) { // Если настроен на ввод
                uint8_t res = 0xFF;
                uint16_t cols = cpu->ppi1_pa | ((cpu->ppi1_pc & 0x0F) << 8);

                if (cols == 0xFFF) { // ХАК: Если процессор завис и выдает 0xFFF, спасаем ввод
                    for (int r = 0; r < 6; r++) {
                        if (spec_key_matrix[r] != 0xFFF) res &= ~(1 << (r + 2));
                    }
                }
                else { // Стандартный опрос
                    for (int r = 0; r < 6; r++) {
                        for (int c = 0; c < 12; c++) {
                            if (!(cols & (1 << c)) && !(spec_key_matrix[r] & (1 << c))) {
                                res &= ~(1 << (r + 2));
                                break;
                            }
                        }
                    }
                }
                return nr_button_pressed ? (res & ~0x02) : (res | 0x02);
            }
            return nr_button_pressed ? (cpu->ppi1_pb & ~0x02) : (cpu->ppi1_pb | 0x02);

        case 2: // --- ПОРТ С (Старшие 4 бита столбцов) ---
            if (cpu->ppi1_ctrl & 0x01) { // Если младшая половина PC на ввод
                uint8_t res = 0x0F;
                for (int r = 0; r < 6; r++) {
                    if (!(cpu->ppi1_pb & (1 << (r + 2))) || spec_key_matrix[r] != 0xFFF) {
                        res &= ((spec_key_matrix[r] >> 8) & 0x0F);
                    }
                }
                return (cpu->ppi1_pc & 0xF0) | res;
            }
            return cpu->ppi1_pc;

        case 3: // Управляющее слово
            return cpu->ppi1_ctrl;
        }
    }

    // Пользовательский ППА №1 (0xF000 - 0xF7FF)
    if (addr >= 0xF000 && addr <= 0xF7FF) {
        switch (addr & 3) {
        case 0: return cpu->ppi0_pa;
        case 1: return cpu->ppi0_pb;
        case 2: return cpu->ppi0_pc;
        case 3: return cpu->ppi0_ctrl;
        }
    }

    return spec_ram[addr]; // Обычное линейное ОЗУ
}

// =========================================================================
// ИСПРАВЛЕННЫЙ АППАРАТНЫЙ ДИСПЕТЧЕР ЗАПИСИ В ПАМЯТЬ И ПОРТОВ
// =========================================================================
void cpu8080_write(CPU8080 *cpu, uint16_t addr, uint8_t val) {
    if (addr >= 0xC000 && addr <= 0xCFFF) return; // ПЗУ защита

    // Обработка системного ППА №2 (Включая зеркало 0xFF00-0xFF03)
    if ((addr >= 0xF800 && addr <= 0xFFFF) || (addr & 0xFFFC) == 0xFF00) {
        uint16_t reg = addr & 3;
        if (reg == 0) { cpu->ppi1_pa = val; }
        else if (reg == 1) { cpu->ppi1_pb = val; }
        else if (reg == 2) {
            cpu->ppi1_pc = val;
            spec_speaker_state = (val & 0x20) != 0; // Звук бипера
        }
        else {
            cpu->ppi1_ctrl = val;
            // --- ДОБАВЛЕНА ПОДДЕРЖКА РЕЖИМА BSR И ЗВУКА ЗАГРУЗЧИКА (STA 0xFF03) ---
            // Если старший бит (Бит 7) равен 0, это команда BSR (побитовое изменение Порта C)
            if ((val & 0x80) == 0) {
                int bit_select = (val >> 1) & 7; // Выделяем номер бита (биты 1-3)
                int bit_value = val & 1;         // Выделяем значение бита (бит 0)

                // Если загрузчик или игра меняет Бит 5 Порта C
                if (bit_select == 5) {
                    spec_speaker_state = (bit_value == 1);
                }

                // Синхронизируем изменение в самом виртуальном порту cpu->ppi1_pc
                if (bit_value) cpu->ppi1_pc |= (1 << bit_select);
                else           cpu->ppi1_pc &= ~(1 << bit_select);
            }
        }
        return;
    }

    // Пользовательский ППА №1
    if (addr >= 0xF000 && addr <= 0xF7FF) {
        uint16_t reg = addr & 3;
        if (reg == 0) cpu->ppi0_pa = val;
        else if (reg == 1) cpu->ppi0_pb = val;
        else if (reg == 2) cpu->ppi0_pc = val;
        else cpu->ppi0_ctrl = val;
        return;
    }

    spec_ram[addr] = val;
}

// Аудио-подсистема
#define AUDIO_RING_SIZE 16384
static int16_t audio_ring_buffer[AUDIO_RING_SIZE];
static _Atomic uint32_t audio_ring_head = 0;   // пишет только основной поток
static _Atomic uint32_t audio_ring_tail = 0;   // пишет только аудиопоток
static uint8_t current_speaker_bit = 0;

void audio_ring_push(int16_t sample) {
    uint32_t head = atomic_load_explicit(&audio_ring_head, memory_order_relaxed);
    uint32_t next_head = (head + 1u) % AUDIO_RING_SIZE;
    uint32_t tail = atomic_load_explicit(&audio_ring_tail, memory_order_acquire);
    if (next_head != tail) {
        audio_ring_buffer[head] = sample;
        atomic_store_explicit(&audio_ring_head, next_head, memory_order_release);
    }
}

// Экземпляр процессора КР580ВМ80А внутри симулятора
static CPU8080 global_cpu;

// Аудиопоток только читает готовые сэмплы. Сэмплы (бипер INTE + каналы ВИ53) формирует
// поток эмуляции в spezialist_execute_cycles: раньше канал ВИ53 микшировался здесь, и на весь
// буфер из 1024 сэмплов брался один и тот же out, то есть тон превращался в постоянный уровень.
void spezialist_get_audio_samples(int16_t *buffer, int sample_count) {
    if (!buffer || sample_count <= 0) return;
    for (int i = 0; i < sample_count; i++) {
        uint32_t tail = atomic_load_explicit(&audio_ring_tail, memory_order_relaxed);
        uint32_t head = atomic_load_explicit(&audio_ring_head, memory_order_acquire);
        if (tail != head) {
            buffer[i] = audio_ring_buffer[tail];
            atomic_store_explicit(&audio_ring_tail, (tail + 1u) % AUDIO_RING_SIZE, memory_order_release);
        } else {
            buffer[i] = spec_speaker_state ? 4000 : -4000;
        }
    }
}

#define AUDIO_SAMPLE_RATE 44100

static uint64_t audio_sample_phase = 0;

void spezialist_execute_cycles(int cycles)
{
    int executed = 0;

    while (executed < cycles) {
        int step_cycles = cpu8080_step(&global_cpu);

        if (step_cycles <= 0) {
            break;
        }

        executed += step_cycles;

        audio_sample_phase +=
            (uint64_t)step_cycles * AUDIO_SAMPLE_RATE;

        while (audio_sample_phase >= CPU_CLOCK_HZ) {
            audio_sample_phase -= CPU_CLOCK_HZ;

            audio_ring_push(spec_speaker_state ? 4000 : -4000);
        }
    }
}

// =========================================================================
//   ФУНКЦИЯ ПРЕЦИЗИОННОГО ВЫВОДА ЭКРАНА С УЧЕТОМ СИНХРОБАЙТОВ ВГ75
//   И АППАРАТНОЙ ОБРАБОТКОЙ КУРСОРA ТИПА ИНВЕРСИЯ (КВАДРАТ)
// =========================================================================
void RenderRkScreen(void) {
    const int tex_width = 384;
    const int tex_height = 256;

    // Цвета Little Endian Mac: color_on - белый символ, color_off - черный фон
    uint32_t color_on = 0x00FFFFFF;
    uint32_t color_off  = 0x00000000;

    // Очищаем экран подложки
    for (int i = 0; i < (tex_width * tex_height); i++) {
        pixel_buffer[i] = color_off;
    }
    
    // Отрисовка по линейной структуре видео-ОЗУ Специалиста:
    // Каждые 256 байт формируют последовательные вертикальные линии шагом в 8 пикселей.
    // Весь экран формируется из 48 колонок байт (48 * 8 = 384 пикселей ширины).
    for (int x_byte = 0; x_byte < 48; x_byte++) {
        for (int y = 0; y < 256; y++) {
            uint16_t addr = 0x9000 + (x_byte * 256) + y;
            uint8_t data_byte = spec_ram[addr];
            
            for (int bit = 0; bit < 8; bit++) {
                bool dot_state = (data_byte & (1 << (7 - bit))) != 0;
                int dest_idx = (y * SCREEN_WIDTH) + (x_byte * 8) + bit;
                pixel_buffer[dest_idx] = dot_state ? color_on : color_off;
            }
        }
    }
}

void spezialist_init(const char *monitor_path, const char* loader_path) {
    memset(spec_ram, 0, sizeof(spec_ram));
    memset(pixel_buffer, 0, sizeof(pixel_buffer));
    
    FILE *f = fopen(monitor_path, "rb");
    if (f) {
        fread(&spec_ram[0xC800], 1, 2048, f);
        fclose(f);
    }
	f = fopen(loader_path, "rb");
	if (f) {
		fread(&spec_ram[0xC000], 1, 2048, f);
		fclose(f);
	}
    // Первоначальный сброс регистров
    spezialist_reset();
}

void spezialist_reset(void) {
    current_speaker_bit = 0;

    // Очередь сбрасывает только производитель: head := tail (tail принадлежит аудиопотоку)
    atomic_store_explicit(&audio_ring_head,
        atomic_load_explicit(&audio_ring_tail, memory_order_acquire), memory_order_release);
    audio_sample_phase = 0;

    nr_button_pressed = false;

    for (int i = 0; i < 6; i++) {
        spec_key_matrix[i] = 0xFFF;
    }

    cpu8080_reset(&global_cpu);
}

void spezialist_run_frame(void) {
    int cycles_per_frame = 40000; // Ровно 40 тыс тактов на кадр при 2 МГц
    spezialist_execute_cycles(cycles_per_frame);

    // Генерация прерывания 50 Гц (если требуется ОС КР580ВМ80А)
    RenderRkScreen();
}

const uint32_t* spezialist_get_pixel_buffer(void) {
    return pixel_buffer;
}

void spezialist_press_key(int row, int bit, bool isPressed) {
    if (row < 0 || row > 5 || bit < 0 || bit > 11) return;
    
    if (isPressed) {
        spec_key_matrix[row] &= ~(1 << bit); // 0 означает, что клавиша замкнута
    } else {
        spec_key_matrix[row] |= (1 << bit);  // 1 означает отпущена
    }
}

// Загрузка бинарных дампов Ориона (.rk)
bool spezialist_load_file(const char* filepath, char* out_msg, size_t msg_max_len) {
    FILE* file = fopen(filepath, "rb");
    if (!file) {
        if (out_msg) snprintf(out_msg, msg_max_len, "Не удалось открыть файл!");
        return false;
    }

    // Вычисляем точный физический размер файла на диске
    fseek(file, 0, SEEK_END);
    long file_size = ftell(file);
    fseek(file, 0, SEEK_SET);
    if (file_size <= 0) {
        fclose(file);
        if (out_msg) snprintf(out_msg, msg_max_len, "Ошибка: файл пуст или его размер не определён.");
        return false;
    }

    // Извлекаем расширение файла вручную (в нижнем регистре)
    char ext[8] = { 0 };
    const char* dot = strrchr(filepath, '.');
    if (dot) {
        int i = 0;
        while (dot[i] && i < 7) {
            // Приведение символов к нижнему регистру
            char c = dot[i];
            if (c >= 'A' && c <= 'Z') c = c + ('a' - 'A');
            ext[i] = c;
            i++;
        }
    }

	uint16_t start_addr = 0;
	uint16_t end_addr = 0;
    uint16_t file_length = 0;
	if (strcmp(ext, ".bin") == 0) {
		file_length = (file_size > 48 * 1024) ? 48 * 1024 : (uint16_t)file_size;
		size_t read_bytes = fread(spec_ram, 1, file_length, file);
		fclose(file);

		if (read_bytes != file_length) {
			if (out_msg) snprintf(out_msg, msg_max_len, "Ошибка чтения данных из файла .bin");
			return false;
		}
		end_addr = read_bytes;
	}
	else if (strcmp(ext, ".rks") == 0) {
        bool has_rks_header = false;

        // Валидация стандартного RKS контейнера (2 байта старта, 2 байта конца)
        if (file_size >= 4) {
            uint8_t header[4];
            size_t read_bytes = fread(header, 1, 4, file);
            if (read_bytes == 4) {
                start_addr = header[0] | (header[1] << 8);
                end_addr = header[2] | (header[3] << 8);

                if (end_addr >= start_addr && (size_t)(end_addr - start_addr + 5) <= file_size) {
                    file_length = end_addr - start_addr + 1;
                    has_rks_header = true;
                }
            }
        }

        if (!has_rks_header) {
            fseek(file, 0, SEEK_SET); // Перемотка в начало, аналог seekg
            file_length = (file_size > 0x9000) ? 0x9000 : (uint16_t)file_size;
        }

		// Считываем бинарные данные напрямую в эмулируемое системное ОЗУ
        size_t read_bytes = fread(&spec_ram[start_addr], 1, file_length, file);
		if (read_bytes < file_length) {
			if (out_msg) snprintf(out_msg, msg_max_len, "Ошибка при чтении данных из файла!");
			fclose(file);
			return false;
		}
		fclose(file);
	}

    // Инициализация CPU для запуска программы
    cpu8080_reset(&global_cpu);
    global_cpu.PC = start_addr;
    global_cpu.SP = 0x8FFF; // Граница пользовательского ОЗУ перед видеообластью

    // Сброс физической матрицы клавиатуры в исходное ненажатое состояние
    for (int i = 0; i < 6; i++) {
        spec_key_matrix[i] = 0xFFF;
    }

    if (out_msg) {
        snprintf(out_msg, msg_max_len,
            "Файл успешно загружен!\nАдреса: %04Xh - %04Xh\nПереход на %04Xh выполнен.",
            start_addr, end_addr, start_addr);
    }

    return true;
}

