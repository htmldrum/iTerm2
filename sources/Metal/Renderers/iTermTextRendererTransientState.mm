//
//  iTermTextRendererTransientState.m
//  iTerm2SharedARC
//
//  Created by George Nachman on 12/22/17.
//

#import "iTermTextRendererTransientState.h"
#import "iTermTextRendererTransientState+Private.h"
#import "iTermPIUArray.h"
#import "iTermSubpixelModelBuilder.h"
#import "iTermTexturePage.h"
#import "iTermTexturePageCollection.h"
#import "NSMutableData+iTerm.h"

#include <map>

namespace iTerm2 {
    class TexturePage;
}

typedef struct {
    size_t piu_index;
    int x;
    int y;
} iTermTextFixup;

// text color component, background color component
typedef std::pair<unsigned char, unsigned char> iTermColorComponentPair;

static vector_uint2 CGSizeToVectorUInt2(const CGSize &size) {
    return simd_make_uint2(size.width, size.height);
}

@implementation iTermTextRendererTransientState {
    // Data's bytes contains a C array of iTermMetalBackgroundColorRLE with background colors.
    NSMutableArray<NSData *> *_backgroundColorRLEDataArray;

    // Info about PIUs that need their background colors set. They belong to
    // parts of glyphs that spilled out of their bounds. The actual PIUs
    // belong to _pius, but are missing some fields.
    std::map<iTerm2::TexturePage *, std::vector<iTermTextFixup> *> _fixups;

    // Color models for this frame. Only used when there's no intermediate texture.
    NSMutableData *_colorModels;

    // Key is text, background color component. Value is color model number (0 is 1st, 1 is 2nd, etc)
    // and you can multiply the color model number by 256 to get its starting point in _colorModels.
    // Only used when there's no intermediate texture.
    std::map<iTermColorComponentPair, int> *_colorModelIndexes;

    NSMutableData *_asciiPIUs[iTermASCIITextureAttributesMax * 2];
    NSInteger _asciiInstances[iTermASCIITextureAttributesMax * 2];

    // Array of PIUs for each texture page.
    std::map<iTerm2::TexturePage *, iTerm2::PIUArray<iTermTextPIU> *> _pius;

    iTermPreciseTimerStats _stats[iTermTextRendererStatCount];
}

- (instancetype)initWithConfiguration:(__kindof iTermRenderConfiguration *)configuration {
    self = [super initWithConfiguration:configuration];
    if (self) {
        _backgroundColorRLEDataArray = [NSMutableArray array];
        iTermCellRenderConfiguration *cellConfiguration = configuration;
        if (!cellConfiguration.usingIntermediatePass) {
            _colorModels = [NSMutableData data];
            _colorModelIndexes = new std::map<iTermColorComponentPair, int>();
        }
    }
    return self;
}

- (void)dealloc {
#warning TODO: Look for memory leaks in the C++ objects
    for (auto pair : _fixups) {
        delete pair.second;
    }
    if (_colorModelIndexes) {
        delete _colorModelIndexes;
    }
    for (auto it = _pius.begin(); it != _pius.end(); it++) {
        delete it->second;
    }
}

- (iTermPreciseTimerStats *)stats {
    return _stats;
}

- (int)numberOfStats {
    return iTermTextRendererStatCount;
}

- (NSString *)nameForStat:(int)i {
    return [@[ @"text.newQuad",
               @"text.newPIU",
               @"text.newDims",
               @"text.subpixel",
               @"text.draw" ] objectAtIndex:i];
}

- (void)enumerateASCIIDraws:(void (^)(const iTermTextPIU *, NSInteger, id<MTLTexture>, vector_uint2, vector_uint2, iTermMetalUnderlineDescriptor))block {
    for (int i = 0; i < iTermASCIITextureAttributesMax * 2; i++) {
        if (_asciiInstances[i]) {
            iTermASCIITexture *asciiTexture = [_asciiTextureGroup asciiTextureForAttributes:(iTermASCIITextureAttributes)i];
            ITBetaAssert(asciiTexture, @"nil ascii texture for attributes %d", i);
            block((iTermTextPIU *)_asciiPIUs[i].mutableBytes,
                  _asciiInstances[i],
                  asciiTexture.textureArray.texture,
                  CGSizeToVectorUInt2(asciiTexture.textureArray.atlasSize),
                  CGSizeToVectorUInt2(_asciiTextureGroup.cellSize),
                  _asciiUnderlineDescriptor);
        }
    }
}

- (void)enumerateNonASCIIDraws:(void (^)(const iTermTextPIU *, NSInteger, id<MTLTexture>, vector_uint2, vector_uint2, iTermMetalUnderlineDescriptor))block {
    for (auto const &mapPair : _pius) {
        const iTerm2::TexturePage *const &texturePage = mapPair.first;
        const iTerm2::PIUArray<iTermTextPIU> *const &piuArray = mapPair.second;

        for (size_t i = 0; i < piuArray->get_number_of_segments(); i++) {
            const size_t count = piuArray->size_of_segment(i);
            if (count > 0) {
                block(piuArray->start_of_segment(i),
                      count,
                      texturePage->get_texture(),
                      texturePage->get_atlas_size(),
                      texturePage->get_cell_size(),
                      _nonAsciiUnderlineDescriptor);
            }
        }
    }
}

- (void)enumerateDraws:(void (^)(const iTermTextPIU *, NSInteger, id<MTLTexture>, vector_uint2, vector_uint2, iTermMetalUnderlineDescriptor))block {
    [self enumerateNonASCIIDraws:block];
    [self enumerateASCIIDraws:block];
}

- (void)willDraw {
    DLog(@"WILL DRAW %@", self);
    // Fix up the background color of parts of glyphs that are drawn outside their cell. Add to the
    // correct page's PIUs.
    const int numRows = _backgroundColorRLEDataArray.count;
        const int width = self.cellConfiguration.gridSize.width;
    for (auto pair : _fixups) {
        iTerm2::TexturePage *page = pair.first;
        std::vector<iTermTextFixup> *fixups = pair.second;
        for (auto fixup : *fixups) {
            iTerm2::PIUArray<iTermTextPIU> &piuArray = *_pius[page];
            iTermTextPIU &piu = piuArray.get(fixup.piu_index);

            // Set fields in piu
            if (fixup.y >= 0 && fixup.y < numRows && fixup.x >= 0 && fixup.x < width) {
                NSData *data = _backgroundColorRLEDataArray[fixup.y];
                const iTermMetalBackgroundColorRLE *backgroundRLEs = (iTermMetalBackgroundColorRLE *)data.bytes;
                // find RLE for index fixup.x
                const int rleCount = data.length / sizeof(iTermMetalBackgroundColorRLE);
                const iTermMetalBackgroundColorRLE &rle = *std::lower_bound(backgroundRLEs,
                                                                            backgroundRLEs + rleCount,
                                                                            static_cast<unsigned short>(fixup.x));
                piu.backgroundColor = rle.color;
                if (_colorModels) {
                    piu.colorModelIndex = [self colorModelIndexForPIU:&piu];
                }
            } else {
                // Offscreen
                piu.backgroundColor = _defaultBackgroundColor;
            }
        }
        delete fixups;
    }

    _fixups.clear();

    for (auto pair : _pius) {
        iTerm2::TexturePage *page = pair.first;
        page->record_use();
    }
    DLog(@"END WILL DRAW");
}

static iTermTextPIU *iTermTextRendererTransientStateAddASCIIPart(iTermTextPIU *piuArray,
                                                                 int i,
                                                                 char code,
                                                                 float w,
                                                                 float h,
                                                                 iTermASCIITexture *texture,
                                                                 float cellWidth,
                                                                 int x,
                                                                 float yOffset,
                                                                 iTermASCIITextureOffset offset,
                                                                 vector_float4 textColor,
                                                                 vector_float4 backgroundColor,
                                                                 iTermMetalGlyphAttributesUnderline underlineStyle,
                                                                 vector_float4 underlineColor) {
    iTermTextPIU *piu = &piuArray[i];
    piu->offset = simd_make_float2(x * cellWidth,
                                   yOffset);
    MTLOrigin origin = [texture.textureArray offsetForIndex:iTermASCIITextureIndexOfCode(code, offset)];
    piu->textureOffset = (vector_float2){ origin.x * w, origin.y * h };
    piu->textColor = textColor;
    piu->backgroundColor = backgroundColor;
    piu->remapColors = YES;
    piu->underlineStyle = underlineStyle;
    piu->underlineColor = underlineColor;
    return piu;
}

- (void)addASCIICellToPIUsForCode:(char)code
                                x:(int)x
                          yOffset:(float)yOffset
                                w:(float)w
                                h:(float)h
                        cellWidth:(float)cellWidth
                       asciiAttrs:(iTermASCIITextureAttributes)asciiAttrs
                       attributes:(const iTermMetalGlyphAttributes *)attributes {
    iTermASCIITexture *texture = [_asciiTextureGroup asciiTextureForAttributes:asciiAttrs];
    NSMutableData *data = _asciiPIUs[asciiAttrs];
    if (!data) {
        data = [NSMutableData dataWithCapacity:_numberOfCells * sizeof(iTermTextPIU) * iTermASCIITextureOffsetCount];
        _asciiPIUs[asciiAttrs] = data;
    }

    iTermTextPIU *piuArray = (iTermTextPIU *)data.mutableBytes;
    iTermASCIITextureParts parts = texture.parts[(size_t)code];
    vector_float4 underlineColor = { 0, 0, 0, 0 };
    if (attributes[x].underlineStyle != iTermMetalGlyphAttributesUnderlineNone) {
        underlineColor = _asciiUnderlineDescriptor.color.w > 0 ? _asciiUnderlineDescriptor.color : attributes[x].foregroundColor;
    }
    // Add PIU for left overflow
    iTermTextPIU *piu;
    if (parts & iTermASCIITexturePartsLeft) {
        if (x > 0) {
            // Normal case
            piu = iTermTextRendererTransientStateAddASCIIPart(piuArray,
                                                              _asciiInstances[asciiAttrs]++,
                                                              code,
                                                              w,
                                                              h,
                                                              texture,
                                                              cellWidth,
                                                              x - 1,
                                                              yOffset,
                                                              iTermASCIITextureOffsetLeft,
                                                              attributes[x].foregroundColor,
                                                              attributes[x - 1].backgroundColor,
                                                              iTermMetalGlyphAttributesUnderlineNone,
                                                              underlineColor);
        } else {
            // Intrusion into left margin
            piu = iTermTextRendererTransientStateAddASCIIPart(piuArray,
                                                              _asciiInstances[asciiAttrs]++,
                                                              code,
                                                              w,
                                                              h,
                                                              texture,
                                                              cellWidth,
                                                              x - 1,
                                                              yOffset,
                                                              iTermASCIITextureOffsetLeft,
                                                              attributes[x].foregroundColor,
                                                              _defaultBackgroundColor,
                                                              iTermMetalGlyphAttributesUnderlineNone,
                                                              underlineColor);
        }
        if (_colorModels) {
            piu->colorModelIndex = [self colorModelIndexForPIU:piu];
        }
    }

    // Add PIU for center part, which is always present
    piu = iTermTextRendererTransientStateAddASCIIPart(piuArray,
                                                      _asciiInstances[asciiAttrs]++,
                                                      code,
                                                      w,
                                                      h,
                                                      texture,
                                                      cellWidth,
                                                      x,
                                                      yOffset,
                                                      iTermASCIITextureOffsetCenter,
                                                      attributes[x].foregroundColor,
                                                      attributes[x].backgroundColor,
                                                      attributes[x].underlineStyle,
                                                      underlineColor);
    if (_colorModels) {
        piu->colorModelIndex = [self colorModelIndexForPIU:piu];
    }

    // Add PIU for right overflow
    if (parts & iTermASCIITexturePartsRight) {
        const int lastColumn = self.cellConfiguration.gridSize.width - 1;
        if (x < lastColumn) {
            // Normal case
            piu = iTermTextRendererTransientStateAddASCIIPart(piuArray,
                                                              _asciiInstances[asciiAttrs]++,
                                                              code,
                                                              w,
                                                              h,
                                                              texture,
                                                              cellWidth,
                                                              x + 1,
                                                              yOffset,
                                                              iTermASCIITextureOffsetRight,
                                                              attributes[x].foregroundColor,
                                                              attributes[x + 1].backgroundColor,
                                                              iTermMetalGlyphAttributesUnderlineNone,
                                                              underlineColor);
        } else {
            // Intrusion into right margin
            piu = iTermTextRendererTransientStateAddASCIIPart(piuArray,
                                                              _asciiInstances[asciiAttrs]++,
                                                              code,
                                                              w,
                                                              h,
                                                              texture,
                                                              cellWidth,
                                                              x + 1,
                                                              yOffset,
                                                              iTermASCIITextureOffsetRight,
                                                              attributes[x].foregroundColor,
                                                              _defaultBackgroundColor,
                                                              iTermMetalGlyphAttributesUnderlineNone,
                                                              underlineColor);
        }
        if (_colorModels) {
            piu->colorModelIndex = [self colorModelIndexForPIU:piu];
        }
    }
}

static inline BOOL GlyphKeyCanTakeASCIIFastPath(const iTermMetalGlyphKey &glyphKey) {
    return (glyphKey.code <= iTermASCIITextureMaximumCharacter &&
            glyphKey.code >= iTermASCIITextureMinimumCharacter &&
            !glyphKey.isComplex &&
            !glyphKey.boxDrawing &&
            !glyphKey.image);
}

- (void)setGlyphKeysData:(NSData *)glyphKeysData
                   count:(int)count
          attributesData:(NSData *)attributesData
                     row:(int)row
  backgroundColorRLEData:(nonnull NSData *)backgroundColorRLEData
                 context:(iTermMetalBufferPoolContext *)context
                creation:(NSDictionary<NSNumber *, iTermCharacterBitmap *> *(NS_NOESCAPE ^)(int x, BOOL *emoji))creation {
    DLog(@"BEGIN setGlyphKeysData for %@", self);
    ITDebugAssert(row == _backgroundColorRLEDataArray.count);
    [_backgroundColorRLEDataArray addObject:backgroundColorRLEData];
    const iTermMetalGlyphKey *glyphKeys = (iTermMetalGlyphKey *)glyphKeysData.bytes;
    const iTermMetalGlyphAttributes *attributes = (iTermMetalGlyphAttributes *)attributesData.bytes;
    vector_float2 asciiCellSize = 1.0 / _asciiTextureGroup.atlasSize;
    const float cellHeight = self.cellConfiguration.cellSize.height;
    const float cellWidth = self.cellConfiguration.cellSize.width;
    const float yOffset = (self.cellConfiguration.gridSize.height - row - 1) * cellHeight;

    std::map<int, int> lastRelations;
    BOOL havePrevious = NO;
    for (int x = 0; x < count; x++) {
        if (!glyphKeys[x].drawable) {
            continue;
        }
        if (GlyphKeyCanTakeASCIIFastPath(glyphKeys[x])) {
            // ASCII fast path
            iTermASCIITextureAttributes asciiAttrs = iTermASCIITextureAttributesFromGlyphKeyTypeface(glyphKeys[x].typeface,
                                                                                                     glyphKeys[x].thinStrokes);
            [self addASCIICellToPIUsForCode:glyphKeys[x].code
                                          x:x
                                    yOffset:yOffset
                                          w:asciiCellSize.x
                                          h:asciiCellSize.y
                                  cellWidth:cellWidth
                                 asciiAttrs:asciiAttrs
                                 attributes:attributes];
            havePrevious = NO;
        } else {
            // Non-ASCII slower path
            const iTerm2::GlyphKey glyphKey(&glyphKeys[x]);
            std::vector<const iTerm2::GlyphEntry *> *entries = _texturePageCollection->find(glyphKey);
            if (!entries) {
                entries = _texturePageCollection->add(x, glyphKey, context, creation);
                if (!entries) {
                    continue;
                }
            }
            for (auto entry : *entries) {
                auto it = _pius.find(entry->_page);
                iTerm2::PIUArray<iTermTextPIU> *array;
                if (it == _pius.end()) {
                    array = _pius[entry->_page] = new iTerm2::PIUArray<iTermTextPIU>(_numberOfCells);
                } else {
                    array = it->second;
                }
                iTermTextPIU *piu = array->get_next();
                // Build the PIU
                const int &part = entry->_part;
                const int dx = iTermImagePartDX(part);
                const int dy = iTermImagePartDY(part);
                piu->offset = simd_make_float2((x + dx) * cellWidth,
                                               -dy * cellHeight + yOffset);
                MTLOrigin origin = entry->get_origin();
                vector_float2 reciprocal_atlas_size = entry->_page->get_reciprocal_atlas_size();
                piu->textureOffset = simd_make_float2(origin.x * reciprocal_atlas_size.x,
                                                      origin.y * reciprocal_atlas_size.y);
                piu->textColor = attributes[x].foregroundColor;
                piu->remapColors = !entry->_is_emoji;
                piu->underlineStyle = attributes[x].underlineStyle;
                piu->underlineColor = _nonAsciiUnderlineDescriptor.color.w > 1 ? _nonAsciiUnderlineDescriptor.color : piu->textColor;

                // Set color info or queue for fixup since color info may not exist yet.
                if (entry->_part == iTermTextureMapMiddleCharacterPart) {
                    piu->backgroundColor = attributes[x].backgroundColor;
                    if (_colorModels) {
                        piu->colorModelIndex = [self colorModelIndexForPIU:piu];
                    }
                } else {
                    iTermTextFixup fixup = {
                        .piu_index = array->size() - 1,
                        .x = x + dx,
                        .y = row + dy,
                    };
                    std::vector<iTermTextFixup> *fixups = _fixups[entry->_page];
                    if (fixups == nullptr) {
                        fixups = new std::vector<iTermTextFixup>();
                        _fixups[entry->_page] = fixups;
                    }
                    fixups->push_back(fixup);
                }
            }
        }
    }
    DLog(@"END setGlyphKeysData for %@", self);
}

- (vector_int3)colorModelIndexForPIU:(iTermTextPIU *)piu {
    iTermColorComponentPair redPair = std::make_pair(piu->textColor.x * 255,
                                                     piu->backgroundColor.x * 255);
    iTermColorComponentPair greenPair = std::make_pair(piu->textColor.y * 255,
                                                       piu->backgroundColor.y * 255);
    iTermColorComponentPair bluePair = std::make_pair(piu->textColor.z * 255,
                                                      piu->backgroundColor.z * 255);
    vector_int3 result;
    auto it = _colorModelIndexes->find(redPair);
    if (it == _colorModelIndexes->end()) {
        result.x = [self allocateColorModelForColorPair:redPair];
    } else {
        result.x = it->second;
    }
    it = _colorModelIndexes->find(greenPair);
    if (it == _colorModelIndexes->end()) {
        result.y = [self allocateColorModelForColorPair:greenPair];
    } else {
        result.y = it->second;
    }
    it = _colorModelIndexes->find(bluePair);
    if (it == _colorModelIndexes->end()) {
        result.z = [self allocateColorModelForColorPair:bluePair];
    } else {
        result.z = it->second;
    }
    return result;
}

- (int)allocateColorModelForColorPair:(iTermColorComponentPair)colorPair {
    int i = _colorModelIndexes->size();
    iTermSubpixelModel *model = [[iTermSubpixelModelBuilder sharedInstance] modelForForegoundColor:colorPair.first / 255.0
                                                                                   backgroundColor:colorPair.second / 255.0];
    [_colorModels appendData:model.table];
    (*_colorModelIndexes)[colorPair] = i;
    return i;
}

- (void)didComplete {
    DLog(@"BEGIN didComplete for %@", self);
    _texturePageCollection->prune_if_needed();
    DLog(@"END didComplete");
}

- (nonnull NSMutableData *)modelData  {
    if (_modelData == nil) {
        _modelData = [[NSMutableData alloc] initWithUninitializedLength:sizeof(iTermTextPIU) * self.cellConfiguration.gridSize.width * self.cellConfiguration.gridSize.height];
    }
    return _modelData;
}

@end

