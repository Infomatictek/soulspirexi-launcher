#pragma once
#include "api.h"
#include <cstdint>
#include <new>

namespace soulspire::native {

constexpr double kAshitaInterfaceVersion = 4.30;

struct AshitaPluginBase {
    virtual const char* GetName(void) const = 0;
    virtual const char* GetAuthor(void) const = 0;
    virtual const char* GetDescription(void) const = 0;
    virtual const char* GetLink(void) const = 0;
    virtual double GetVersion(void) const = 0;
    virtual double GetInterfaceVersion(void) const = 0;
    virtual int32_t GetPriority(void) const = 0;
    virtual uint32_t GetFlags(void) const = 0;
    virtual bool Initialize(void* core, void* logger, uint32_t id) = 0;
    virtual void Release(void) = 0;
    virtual void HandleEvent(const char* eventName, const void* eventData, uint32_t eventSize) = 0;
    virtual bool HandleCommand(int32_t mode, const char* command, bool injected) = 0;
    virtual bool HandleIncomingText(int32_t mode, bool indent, const char* message, int32_t* modifiedMode, bool* modifiedIndent, char* modifiedMessage, bool injected, bool blocked) = 0;
    virtual bool HandleOutgoingText(int32_t mode, const char* message, int32_t* modifiedMode, char* modifiedMessage, bool injected, bool blocked) = 0;
    virtual bool HandleIncomingPacket(uint16_t id, uint32_t size, const uint8_t* data, uint8_t* modified, uint32_t sizeChunk, const uint8_t* dataChunk, bool injected, bool blocked) = 0;
    virtual bool HandleOutgoingPacket(uint16_t id, uint32_t size, const uint8_t* data, uint8_t* modified, uint32_t sizeChunk, const uint8_t* dataChunk, bool injected, bool blocked) = 0;
    virtual bool Direct3DInitialize(void* device) = 0;
    virtual void Direct3DBeginScene(bool isRenderingBackBuffer) = 0;
    virtual void Direct3DEndScene(bool isRenderingBackBuffer) = 0;
    virtual void Direct3DPresent(const RECT* pSourceRect, const RECT* pDestRect, HWND hDestWindowOverride, const RGNDATA* pDirtyRegion) = 0;
    virtual bool Direct3DSetRenderState(uint32_t State, DWORD* Value) = 0;
    virtual bool Direct3DDrawPrimitive(uint32_t PrimitiveType, UINT StartVertex, UINT PrimitiveCount) = 0;
    virtual bool Direct3DDrawIndexedPrimitive(uint32_t PrimitiveType, UINT minIndex, UINT NumVertices, UINT startIndex, UINT primCount) = 0;
    virtual bool Direct3DDrawPrimitiveUP(uint32_t PrimitiveType, UINT PrimitiveCount, const void* pVertexStreamZeroData, UINT VertexStreamZeroStride) = 0;
    virtual bool Direct3DDrawIndexedPrimitiveUP(uint32_t PrimitiveType, UINT MinVertexIndex, UINT NumVertexIndices, UINT PrimitiveCount, const void* pIndexData, uint32_t IndexDataFormat, const void* pVertexStreamZeroData, UINT VertexStreamZeroStride) = 0;
};

class SoulspireNativePlugin final : public AshitaPluginBase {
public:
    SoulspireNativePlugin() = default;
    ~SoulspireNativePlugin() = default;

    const char* GetName(void) const override { return "soulspire_native"; }
    const char* GetAuthor(void) const override { return "SoulspireXI"; }
    const char* GetDescription(void) const override {
        return "SoulspireXI native client foundation (Soul identities, actions, equipment, and menus).";
    }
    const char* GetLink(void) const override { return "https://github.com/Infomatictek/soulspirexi-launcher"; }
    double GetVersion(void) const override { return 2.00; }
    double GetInterfaceVersion(void) const override { return kAshitaInterfaceVersion; }
    int32_t GetPriority(void) const override { return 0; }
    uint32_t GetFlags(void) const override { return 0; }

    bool Initialize(void*, void*, uint32_t) override {
        SoulspireNativeInitialize();
        return true;
    }

    void Release(void) override {
        SoulspireNativeShutdown();
    }

    void HandleEvent(const char*, const void*, uint32_t) override {}
    bool HandleCommand(int32_t, const char*, bool) override { return false; }
    bool HandleIncomingText(int32_t, bool, const char*, int32_t*, bool*, char*, bool, bool) override { return false; }
    bool HandleOutgoingText(int32_t, const char*, int32_t*, char*, bool, bool) override { return false; }
    bool HandleIncomingPacket(uint16_t, uint32_t, const uint8_t*, uint8_t*, uint32_t, const uint8_t*, bool, bool) override { return false; }
    bool HandleOutgoingPacket(uint16_t, uint32_t, const uint8_t*, uint8_t*, uint32_t, const uint8_t*, bool, bool) override { return false; }
    bool Direct3DInitialize(void*) override {
        SoulspireNativeInitialize();
        return true;
    }
    void Direct3DBeginScene(bool) override {}
    void Direct3DEndScene(bool) override {}
    void Direct3DPresent(const RECT*, const RECT*, HWND, const RGNDATA*) override {}
    bool Direct3DSetRenderState(uint32_t, DWORD*) override { return false; }
    bool Direct3DDrawPrimitive(uint32_t, UINT, UINT) override { return false; }
    bool Direct3DDrawIndexedPrimitive(uint32_t, UINT, UINT, UINT, UINT) override { return false; }
    bool Direct3DDrawPrimitiveUP(uint32_t, UINT, const void*, UINT) override { return false; }
    bool Direct3DDrawIndexedPrimitiveUP(uint32_t, UINT, UINT, UINT, const void*, uint32_t, const void*, UINT) override { return false; }
};

} // namespace soulspire::native
