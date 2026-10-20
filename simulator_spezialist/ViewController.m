// ViewController.m
#import "ViewController.h"
#import "simulator_spezialist.h"
#import <Carbon/Carbon.h>
#import <AudioToolbox/AudioToolbox.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#define AUDIO_SAMPLE_RATE 44100
#define AUDIO_BUFFER_SIZE 1024

extern bool nr_button_pressed;
extern uint16_t spec_key_matrix[6];

// Время удержания РУС/ЛАТ: монитор опрашивает клавиатуру раз в несколько кадров
#define RUS_LAT_HOLD_SECONDS 0.1

// stringWithUTF8String: возвращает nil на невалидном UTF-8 (например, имя файла ORDOS в КОИ-8),
// а NSAlert не принимает nil. Битые байты заменяем на '?'.
static NSString *SafeUTF8String(const char *msg) {
    NSString *s = [NSString stringWithUTF8String:msg];
    if (s) return s;
    size_t n = strlen(msg);
    NSMutableData *out = [NSMutableData dataWithCapacity:n];
    for (size_t i = 0; i < n; ) {
        unsigned char c = (unsigned char)msg[i];
        size_t len = c < 0x80 ? 1 : (c >= 0xC2 && c <= 0xDF) ? 2 : (c >= 0xE0 && c <= 0xEF) ? 3 : (c >= 0xF0 && c <= 0xF4) ? 4 : 0;
        BOOL ok = len > 0 && i + len <= n;
        for (size_t k = 1; ok && k < len; k++) ok = (((unsigned char)msg[i + k]) & 0xC0) == 0x80;
        if (ok) { [out appendBytes:msg + i length:len]; i += len; }
        else    { [out appendBytes:"?" length:1]; i++; }
    }
    s = [[NSString alloc] initWithData:out encoding:NSUTF8StringEncoding];
    return s ?: @"(сообщение недоступно)";
}

@interface ViewController () {
    AudioQueueRef audioQueue;
    AudioQueueBufferRef audioBuffers[2];
    NSUInteger _rusLatToken;   // поколение нажатия РУС/ЛАТ: устаревшие отложенные отпускания игнорируются
    BOOL _lastCapsLock;        // предыдущее состояние Caps Lock
}
@end

@implementation ViewController

static void AudioQueueCallback(void *inUserData, AudioQueueRef inAQ, AudioQueueBufferRef inBuffer) {
    int sampleCount = inBuffer->mAudioDataBytesCapacity / sizeof(int16_t);
    spezialist_get_audio_samples((int16_t *)inBuffer->mAudioData, sampleCount);
    inBuffer->mAudioDataByteSize = inBuffer->mAudioDataBytesCapacity;
    AudioQueueEnqueueBuffer(inAQ, inBuffer, 0, NULL);
}

- (void)viewDidLoad {
    [super viewDidLoad];
    
    _lastCapsLock = ([NSEvent modifierFlags] & NSEventModifierFlagCapsLock) != 0;
    
    // Инициализация слоя рендеринга CoreAnimation
    self.view.wantsLayer = YES;
    self.emulationLayer = [CALayer layer];
    self.emulationLayer.frame = self.view.bounds;
    self.emulationLayer.contentsGravity = kCAGravityResizeAspect;
    
    // Pixel-art фильтрация
    self.emulationLayer.magnificationFilter = kCAFilterNearest;
    [self.view.layer addSublayer:self.emulationLayer];
    
    // Поиск файла прошивки ROM BIOS
    NSString *monitorPath = [[NSBundle mainBundle] pathForResource:@"monitor" ofType:@"bin"];
    if (!monitorPath) {
        NSAlert *alert = [[NSAlert alloc] init];
        [alert setMessageText:@"Ошибка ресурсов"];
        [alert setInformativeText:@"Файл 'monitor.bin' не найден в Bundle приложения.\nДобавьте образ BIOS Монитора в Xcode."];
        [alert setAlertStyle:NSAlertStyleCritical];
        [alert runModal];
        
        dispatch_async(dispatch_get_main_queue(), ^{
            [NSApp terminate:nil];
        });
        return;
    }
    // Поиск файла прошивки LOADER ROM
    NSString *fontPath = [[NSBundle mainBundle] pathForResource:@"loader" ofType:@"bin"];
    if (!fontPath) {
        NSAlert *alert = [[NSAlert alloc] init];
        [alert setMessageText:@"Ошибка ресурсов"];
        [alert setInformativeText:@"Файл 'loader.bin' не найден в Bundle приложения.\nДобавьте образ LOADER ROM в Xcode."];
        [alert setAlertStyle:NSAlertStyleCritical];
        [alert runModal];
        
        dispatch_async(dispatch_get_main_queue(), ^{
            [NSApp terminate:nil];
        });
        return;
    }
    
    spezialist_init([monitorPath UTF8String], [fontPath UTF8String]);
    [self initAudioEngine];
    [self startEmulation];
}

- (void)initAudioEngine {
    AudioStreamBasicDescription format = {0};

    format.mSampleRate = AUDIO_SAMPLE_RATE;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags =
        kLinearPCMFormatFlagIsSignedInteger |
        kLinearPCMFormatFlagIsPacked;
    format.mBytesPerPacket = sizeof(int16_t);
    format.mFramesPerPacket = 1;
    format.mBytesPerFrame = sizeof(int16_t);
    format.mChannelsPerFrame = 1;
    format.mBitsPerChannel = 16;

    OSStatus status = AudioQueueNewOutput(
        &format,
        AudioQueueCallback,
        (__bridge void *)(self),
        NULL,
        NULL,
        0,
        &audioQueue
    );

    if (status != noErr || !audioQueue) {
        NSLog(@"AudioQueueNewOutput failed: %d", (int)status);
        return;
    }

    for (int i = 0; i < 2; i++) {
        status = AudioQueueAllocateBuffer(
            audioQueue,
            AUDIO_BUFFER_SIZE * sizeof(int16_t),
            &audioBuffers[i]
        );

        if (status != noErr) {
            NSLog(@"AudioQueueAllocateBuffer failed: %d",
                  (int)status);

            AudioQueueDispose(audioQueue, true);
            audioQueue = NULL;

            for (int j = 0; j < i; j++) {
                audioBuffers[j] = NULL;
            }

            return;
        }

        AudioQueueCallback(
            (__bridge void *)(self),
            audioQueue,
            audioBuffers[i]
        );
    }

    status = AudioQueueStart(audioQueue, NULL);

    if (status != noErr) {
        NSLog(@"AudioQueueStart failed: %d", (int)status);
        AudioQueueDispose(audioQueue, true);
        audioQueue = NULL;

        audioBuffers[0] = NULL;
        audioBuffers[1] = NULL;
    }
}

- (void)dealloc {
    [self stopEmulation];

    if (audioQueue) {
        AudioQueueStop(audioQueue, true);
        AudioQueueDispose(audioQueue, true);
        audioQueue = NULL;
    }
}

- (void)viewDidLayout {
    [super viewDidLayout];
    self.emulationLayer.frame = self.view.bounds;
}

- (void)startEmulation {
    [self stopEmulation];
    // Интервал 0.02 секунды соответствует кадровой частоте развертки 50 Гц
    // Блочный таймер со слабой ссылкой: NSTimer с target:self удерживал бы контроллер,
    // и dealloc (а с ним остановка таймера и аудио) никогда бы не вызвался
    __weak typeof(self) weakSelf = self;
    self.emulationTimer = [NSTimer timerWithTimeInterval:0.02 repeats:YES block:^(NSTimer *timer) {
        ViewController *strongSelf = weakSelf;
        if (!strongSelf) {
            [timer invalidate];
            return;
        }
        [strongSelf emulationLoop];
    }];
    [[NSRunLoop currentRunLoop] addTimer:self.emulationTimer forMode:NSRunLoopCommonModes];
}

- (void)stopEmulation {
    if (self.emulationTimer) {
        [self.emulationTimer invalidate];
        self.emulationTimer = nil;
    }
}

- (void)emulationLoop {
    spezialist_run_frame();
    const uint32_t *buffer = spezialist_get_pixel_buffer();
    [self updateViewWithBuffer:buffer];
}

- (void)updateViewWithBuffer:(const uint32_t *)pixelBuffer {
    if (!pixelBuffer) return;

    size_t bufferSize = SCREEN_WIDTH * SCREEN_HEIGHT * 4;
    CFDataRef dataRef = CFDataCreate(kCFAllocatorDefault, (const UInt8 *)pixelBuffer, bufferSize);
    if (!dataRef) return;

    CGDataProviderRef provider = CGDataProviderCreateWithCFData(dataRef);
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    
    CGImageRef imageRef = CGImageCreate(
        SCREEN_WIDTH, SCREEN_HEIGHT,
        8, 32, SCREEN_WIDTH * 4,
        colorSpace,
        kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst,
        provider, NULL, NO, kCGRenderingIntentDefault
    );
    
    if (imageRef) {
        // У отдельного CALayer смена contents по умолчанию анимируется (кроссфейд) - отключаем
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        self.emulationLayer.contents = (__bridge id _Nullable)(imageRef);
        [CATransaction commit];
        CGImageRelease(imageRef);
    }
    
    CGColorSpaceRelease(colorSpace);
    CGDataProviderRelease(provider);
    CFRelease(dataRef);
}

// ИСПРАВЛЕНО: Точное побитовое соответствие функции MapVirtualKeyToSpec из Windows
static BOOL MapMacKeyToSpecDirect(unsigned short keyCode, int *out_row, int *out_col) {
    switch (keyCode) {
        // --- ЦИФРОВОЙ РЯД ---
        case kVK_ANSI_Grave:        *out_row = 3; *out_col = 0;  return YES; // ; +
        case kVK_ANSI_1:            *out_row = 4; *out_col = 10; return YES; // 1 !
        case kVK_ANSI_2:            *out_row = 4; *out_col = 9;  return YES; // 2 "
        case kVK_ANSI_3:            *out_row = 4; *out_col = 8;  return YES; // 3 #
        case kVK_ANSI_4:            *out_row = 4; *out_col = 7;  return YES; // 4 $
        case kVK_ANSI_5:            *out_row = 4; *out_col = 6;  return YES; // 5 %
        case kVK_ANSI_6:            *out_row = 4; *out_col = 5;  return YES; // 6 &
        case kVK_ANSI_7:            *out_row = 4; *out_col = 4;  return YES; // 7 ,
        case kVK_ANSI_8:            *out_row = 4; *out_col = 3;  return YES; // 8 (
        case kVK_ANSI_9:            *out_row = 4; *out_col = 2;  return YES; // 9 )
        case kVK_ANSI_0:            *out_row = 4; *out_col = 1;  return YES; // 0
        case kVK_ANSI_Minus:        *out_row = 4; *out_col = 0;  return YES; // - =
        
        // --- ЛАТИНСКИЕ БУКВЫ A-Z (Маппинг "Буква в Букву" для Специалиста) ---
        case kVK_ANSI_A:            *out_row = 2; *out_col = 8;  return YES; // A -> на позицию А / A
        case kVK_ANSI_B:            *out_row = 1; *out_col = 4;  return YES; // B -> на позицию Б / B
        case kVK_ANSI_C:            *out_row = 3; *out_col = 10; return YES; // C -> на позицию Ц / C
        case kVK_ANSI_D:            *out_row = 2; *out_col = 3;  return YES; // D -> на позицию Д / D
        case kVK_ANSI_E:            *out_row = 3; *out_col = 7;  return YES; // E -> на позицию Е / E
        case kVK_ANSI_F:            *out_row = 2; *out_col = 11; return YES; // F -> на позицию Ф / F
        case kVK_ANSI_G:            *out_row = 3; *out_col = 5;  return YES; // G -> на позицию Г / G
        case kVK_ANSI_H:            *out_row = 3; *out_col = 1;  return YES; // H -> на позицию Х / H
        case kVK_ANSI_I:            *out_row = 1; *out_col = 7;  return YES; // I -> на позицию И / I
        case kVK_ANSI_J:            *out_row = 3; *out_col = 11; return YES; // J -> на позицию Й / J
        case kVK_ANSI_K:            *out_row = 3; *out_col = 8;  return YES; // K -> на позицию К / K
        case kVK_ANSI_L:            *out_row = 2; *out_col = 4;  return YES; // L -> на позицию Л / L
        case kVK_ANSI_M:            *out_row = 1; *out_col = 8;  return YES; // M -> на позицию М / M
        case kVK_ANSI_N:            *out_row = 3; *out_col = 6;  return YES; // N -> на позицию Н / N
        case kVK_ANSI_O:            *out_row = 2; *out_col = 5;  return YES; // O -> на позицию О / O
        case kVK_ANSI_P:            *out_row = 2; *out_col = 7;  return YES; // P -> на позицию П / P
        case kVK_ANSI_Q:            *out_row = 1; *out_col = 11; return YES; // Q -> на позицию Я / Q
        case kVK_ANSI_R:            *out_row = 2; *out_col = 6;  return YES; // R -> на позицию Р / R
        case kVK_ANSI_S:            *out_row = 1; *out_col = 9;  return YES; // S -> на позицию С / S
        case kVK_ANSI_T:            *out_row = 1; *out_col = 6;  return YES; // T -> на позицию Т / T
        case kVK_ANSI_U:            *out_row = 3; *out_col = 9;  return YES; // U -> на позицию У / U
        case kVK_ANSI_V:            *out_row = 2; *out_col = 2;  return YES; // V -> на позицию Ж / V
        case kVK_ANSI_W:            *out_row = 2; *out_col = 9;  return YES; // W -> на позицию В / W
        case kVK_ANSI_X:            *out_row = 1; *out_col = 5;  return YES; // X -> на позицию Ь / X
        case kVK_ANSI_Y:            *out_row = 2; *out_col = 10; return YES; // Y -> на позицию Ы / Y
        case kVK_ANSI_Z:            *out_row = 3; *out_col = 2;  return YES; // Z -> на позицию З / Z

        // --- СПЕЦИАЛЬНЫЕ СИМВОЛЫ И КЛАВИШИ ---
        case kVK_ANSI_LeftBracket:  *out_row = 3; *out_col = 4;  return YES; // [ -> на Ш / [
        case kVK_ANSI_RightBracket: *out_row = 3; *out_col = 3;  return YES; // ] -> на Щ / ]
        case kVK_ANSI_Semicolon:    *out_row = 1; *out_col = 3;  return YES; // ; -> на : / *
        case kVK_ANSI_Quote:        *out_row = 1; *out_col = 10; return YES; // ' -> на Э
        case kVK_ANSI_Backslash:    *out_row = 2; *out_col = 1;  return YES; // \ -> на : / *
        case kVK_ANSI_Comma:        *out_row = 1; *out_col = 2;  return YES; // , -> на , / <
        case kVK_ANSI_Period:       *out_row = 2; *out_col = 0;  return YES; // . -> на . / >
        case kVK_ANSI_Slash:        *out_row = 1; *out_col = 1;  return YES; // / -> на / / ?
        
        // --- СИСТЕМНЫЕ КЛАВИШИ И СТРЕЛКИ ---
        case kVK_Return:            *out_row = 0; *out_col = 0;  return YES; // ВК (Enter)
        case kVK_Delete:            *out_row = 1; *out_col = 0;  return YES; // Backspace -> ЗБ
        case kVK_Space:             *out_row = 0; *out_col = 5;  return YES; // Пробел
        case kVK_Tab:               *out_row = 0; *out_col = 7;  return YES; // ТАБ
        case kVK_Escape:            *out_row = 0; *out_col = 6;  return YES; // АР2
        case kVK_Home:              *out_row = 0; *out_col = 10; return YES; // HOME
        case kVK_UpArrow:           *out_row = 0; *out_col = 9;  return YES; // Стрелка Вверх
        case kVK_DownArrow:         *out_row = 0; *out_col = 8;  return YES; // Стрелка Вниз
        case kVK_LeftArrow:         *out_row = 0; *out_col = 4;  return YES; // Стрелка Влево
        case kVK_RightArrow:        *out_row = 0; *out_col = 2;  return YES; // Стрелка Вправо

        // --- ФУНКЦИОНАЛЬНЫЙ РЯД ---
        case kVK_F1:                *out_row = 5; *out_col = 11; return YES;
        case kVK_F2:                *out_row = 5; *out_col = 10; return YES;
        case kVK_F3:                *out_row = 5; *out_col = 9;  return YES;
        case kVK_F4:                *out_row = 5; *out_col = 8;  return YES;
        case kVK_F5:                *out_row = 5; *out_col = 7;  return YES;
        case kVK_F6:                *out_row = 5; *out_col = 6;  return YES;
        case kVK_F7:                *out_row = 5; *out_col = 5;  return YES;
        case kVK_F8:                *out_row = 5; *out_col = 4;  return YES;
        case kVK_F9:                *out_row = 5; *out_col = 3;  return YES;
        case kVK_F10:               *out_row = 5; *out_col = 2;  return YES;
        case kVK_F11:               *out_row = 5; *out_col = 1;  return YES;
        case kVK_F12:               *out_row = 5; *out_col = 0;  return YES;

        default: break;
    }
    return NO;
}

- (void)handleKeyEvent:(NSEvent *)event isPressed:(BOOL)isPressed {
    unsigned short keyCode = [event keyCode];
    
    int row = -1, col = -1;
    // Вызов обновленной функции прямого маппинга
    if (MapMacKeyToSpecDirect(keyCode, &row, &col)) {
        if (row >= 0 && row < 6 && col >= 0 && col < 12) {
            spezialist_press_key(row, col, isPressed);
        }
    }
}

- (void)flagsChanged:(NSEvent *)event {
    NSEventModifierFlags modifierFlags = [event modifierFlags];
    
    // 1. ИСПРАВЛЕНО: Синхронизация физического Shift с системной кнопкой НР
    nr_button_pressed = (modifierFlags & NSEventModifierFlagShift) != 0;
    
    // 2. ИСПРАВЛЕНО: Эмуляция кнопки РУС/ЛАТ (Строка 0, Бит 11) через фиксатор Caps Lock в точном соответствии с Windows
    BOOL currentCapsLock = (modifierFlags & NSEventModifierFlagCapsLock) != 0;
    if (currentCapsLock != _lastCapsLock) {
        _lastCapsLock = currentCapsLock;
        
        // Замыкаем контакт РУС/ЛАТ на время опроса Монитором
        spec_key_matrix[0] &= ~(1 << 11);
        
        NSUInteger token = ++_rusLatToken;
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(RUS_LAT_HOLD_SECONDS * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            ViewController *strongSelf = weakSelf;
            if (strongSelf && strongSelf->_rusLatToken == token) {
                // Размыкаем контакт по истечении тайм-аута (возвращаем 1)
                spec_key_matrix[0] |= (1 << 11);
            }
        });
    }
    
    [super flagsChanged:event];
}

- (BOOL)acceptsFirstResponder { return YES; }

- (void)keyDown:(NSEvent *)event {
    if (![event isARepeat]) {
        [self handleKeyEvent:event isPressed:YES];
    }
}

- (void)keyUp:(NSEvent *)event {
    [self handleKeyEvent:event isPressed:NO];
}

- (void)viewDidAppear {
    [super viewDidAppear];
    [self setupMenu];
    [self.view.window makeFirstResponder:self];
}

- (void)setupMenu {
    NSMenu *mainMenu = [NSApp mainMenu];
    NSMenuItem *fileMenuItem = [mainMenu itemWithTitle:@"File"];
    if (!fileMenuItem) {
        fileMenuItem = [[NSMenuItem alloc] initWithTitle:@"File" action:nil keyEquivalent:@""];
        [mainMenu addItem:fileMenuItem];
    }
    NSMenu *fileMenu = [fileMenuItem submenu] ? [fileMenuItem submenu] : [[NSMenu alloc] initWithTitle:@"File"];
    [fileMenuItem setSubmenu:fileMenu];
    
    [fileMenu addItem:[NSMenuItem separatorItem]];
    
    NSMenuItem *openItem = [[NSMenuItem alloc] initWithTitle:@"Open Spezialist File (*.rks;*.bin)"
                                                      action:@selector(triggerOpenFile:)
                                               keyEquivalent:@"o"];
    [openItem setTarget:self];
    [fileMenu addItem:openItem];
    
    NSMenuItem *resetItem = [[NSMenuItem alloc] initWithTitle:@"Hard Reset"
                                                       action:@selector(triggerReset:)
                                                keyEquivalent:@"r"];
    [resetItem setTarget:self];
    [fileMenu addItem:resetItem];
}

- (void)triggerOpenFile:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = NO;
    panel.allowsMultipleSelection = NO;
    
    // Ограничиваем выбор файлами .ord и .bin
    if (@available(macOS 11.0, *)) {
        panel.allowedContentTypes = @[
            [UTType typeWithFilenameExtension:@"rks"],
            [UTType typeWithFilenameExtension:@"bin"]
        ];
    } else {
        panel.allowedFileTypes = @[@"rks", @"bin"];
    }
    
    [panel beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse result) {
        if (result == NSModalResponseOK) {
            NSURL *fileURL = panel.URL;
            if (fileURL) {
                // 1. Временно останавливаем таймер эмуляции, чтобы избежать конфликтов по памяти
                [self stopEmulation];
                
                // Buffer для сообщения об успехе/ошибке из Си-кода
                char msgBuffer[512] = {0};
                
                // 2. Вызываем Си-функцию загрузки
                BOOL success = spezialist_load_file([fileURL.path UTF8String], msgBuffer, sizeof(msgBuffer));
                
                // 3. Показываем результат пользователю
                NSAlert *alert = [[NSAlert alloc] init];
                if (success) {
                    [alert setMessageText:@"Успешная загрузка"];
                    [alert setAlertStyle:NSAlertStyleInformational];
                } else {
                    [alert setMessageText:@"Ошибка загрузки"];
                    [alert setAlertStyle:NSAlertStyleWarning];
                }
                [alert setInformativeText:SafeUTF8String(msgBuffer)];
                [alert runModal];
                
                // 4. Перезапускаем эмуляцию (процессор начнет выполнять код с нового PC)
                [self startEmulation];
                NSLog(@"Spezialist File Bootstrapped: %s", msgBuffer);
            }
        }
    }];
}

- (void)triggerReset:(id)sender {
    [self stopEmulation];
    spezialist_reset();
    [self startEmulation];
    NSLog(@"Spezialist Hardware Reset Triggered.");
}

@end
