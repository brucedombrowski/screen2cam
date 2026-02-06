/*
 * Windows Screen Capture Module (DXGI Desktop Duplication)
 *
 * Implements the capture.h interface using DXGI 1.2 Desktop Duplication API.
 * Works on Windows 8+ with no admin rights and no installation required.
 *
 * Architecture:
 *   - Create D3D11 device -> get DXGI adapter -> get output (monitor)
 *   - DuplicateOutput() for desktop duplication
 *   - Each capture_grab() call: AcquireNextFrame -> copy to staging texture
 *     -> Map -> copy BGRA pixels -> Unmap -> ReleaseFrame
 *
 * Pixel format: BGRA (DXGI_FORMAT_B8G8R8A8_UNORM) — matches capture.h contract.
 *
 * COM usage: Plain C with COBJMACROS (no C++). All COM calls via vtable macros.
 */

#define COBJMACROS
#define CINTERFACE

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif

#include "capture.h"

#include <windows.h>
#include <d3d11.h>
#include <dxgi1_2.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* GUIDs — MinGW headers may not provide these */
#ifndef __IID_DEFINED__
#define __IID_DEFINED__
#endif

/* Fallback GUID definitions if not provided by headers */
static const GUID local_IID_IDXGIDevice   = {0x54ec77fa,0x1377,0x44e6,{0x8c,0x32,0x88,0xfd,0x5f,0x44,0xc8,0x4c}};
static const GUID local_IID_IDXGIAdapter  = {0x2411e7e1,0x12ac,0x4ccf,{0xbd,0x14,0x97,0x98,0xe8,0x53,0x4d,0xc0}};
static const GUID local_IID_IDXGIOutput1  = {0x00cddea8,0x939b,0x4b83,{0xa3,0x40,0xa6,0x85,0x22,0x66,0x66,0xcc}};

struct capture_ctx {
    ID3D11Device            *device;
    ID3D11DeviceContext     *context;
    IDXGIOutputDuplication  *duplication;
    ID3D11Texture2D         *staging;
    int                      width;
    int                      height;
    uint8_t                 *buffer;
    size_t                   buffer_size;
};

capture_ctx_t *capture_init(void)
{
    HRESULT hr;

    /* Initialize COM for this thread */
    hr = CoInitializeEx(NULL, COINIT_MULTITHREADED);
    if (FAILED(hr) && hr != S_FALSE && hr != RPC_E_CHANGED_MODE) {
        fprintf(stderr, "capture_win: CoInitializeEx failed: 0x%08lx\n", (unsigned long)hr);
        return NULL;
    }

    capture_ctx_t *ctx = calloc(1, sizeof(*ctx));
    if (!ctx)
        return NULL;

    /* Create D3D11 device */
    D3D_FEATURE_LEVEL feature_level;
    hr = D3D11CreateDevice(
        NULL,                       /* default adapter */
        D3D_DRIVER_TYPE_HARDWARE,
        NULL,                       /* no software rasterizer */
        0,                          /* flags */
        NULL, 0,                    /* default feature levels */
        D3D11_SDK_VERSION,
        &ctx->device,
        &feature_level,
        &ctx->context
    );
    if (FAILED(hr)) {
        fprintf(stderr, "capture_win: D3D11CreateDevice failed: 0x%08lx\n", (unsigned long)hr);
        free(ctx);
        return NULL;
    }

    /* D3D11 Device -> DXGI Device -> DXGI Adapter -> DXGI Output -> Output1 -> DuplicateOutput */
    IDXGIDevice *dxgi_device = NULL;
    hr = ID3D11Device_QueryInterface(ctx->device, &local_IID_IDXGIDevice, (void **)&dxgi_device);
    if (FAILED(hr)) {
        fprintf(stderr, "capture_win: QueryInterface(IDXGIDevice) failed: 0x%08lx\n", (unsigned long)hr);
        goto fail;
    }

    IDXGIAdapter *adapter = NULL;
    hr = IDXGIDevice_GetAdapter(dxgi_device, &adapter);
    IDXGIDevice_Release(dxgi_device);
    if (FAILED(hr)) {
        fprintf(stderr, "capture_win: GetAdapter failed: 0x%08lx\n", (unsigned long)hr);
        goto fail;
    }

    IDXGIOutput *output = NULL;
    hr = IDXGIAdapter_EnumOutputs(adapter, 0, &output);
    IDXGIAdapter_Release(adapter);
    if (FAILED(hr)) {
        fprintf(stderr, "capture_win: EnumOutputs(0) failed: 0x%08lx\n", (unsigned long)hr);
        fprintf(stderr, "capture_win: no display output found\n");
        goto fail;
    }

    /* Get output dimensions from DXGI_OUTPUT_DESC */
    DXGI_OUTPUT_DESC out_desc;
    IDXGIOutput_GetDesc(output, &out_desc);
    ctx->width  = out_desc.DesktopCoordinates.right  - out_desc.DesktopCoordinates.left;
    ctx->height = out_desc.DesktopCoordinates.bottom - out_desc.DesktopCoordinates.top;

    /* QueryInterface for IDXGIOutput1 (Desktop Duplication requires DXGI 1.2) */
    IDXGIOutput1 *output1 = NULL;
    hr = IDXGIOutput_QueryInterface(output, &local_IID_IDXGIOutput1, (void **)&output1);
    IDXGIOutput_Release(output);
    if (FAILED(hr)) {
        fprintf(stderr, "capture_win: QueryInterface(IDXGIOutput1) failed: 0x%08lx\n", (unsigned long)hr);
        fprintf(stderr, "capture_win: Desktop Duplication requires Windows 8 or later\n");
        goto fail;
    }

    /* Duplicate the desktop output */
    hr = IDXGIOutput1_DuplicateOutput(output1, (IUnknown *)ctx->device, &ctx->duplication);
    IDXGIOutput1_Release(output1);
    if (FAILED(hr)) {
        fprintf(stderr, "capture_win: DuplicateOutput failed: 0x%08lx\n", (unsigned long)hr);
        if (hr == E_ACCESSDENIED)
            fprintf(stderr, "capture_win: access denied — is another app using Desktop Duplication?\n");
        goto fail;
    }

    /* Create CPU-readable staging texture for pixel readback */
    D3D11_TEXTURE2D_DESC staging_desc = {0};
    staging_desc.Width              = (UINT)ctx->width;
    staging_desc.Height             = (UINT)ctx->height;
    staging_desc.MipLevels          = 1;
    staging_desc.ArraySize          = 1;
    staging_desc.Format             = DXGI_FORMAT_B8G8R8A8_UNORM;
    staging_desc.SampleDesc.Count   = 1;
    staging_desc.SampleDesc.Quality = 0;
    staging_desc.Usage              = D3D11_USAGE_STAGING;
    staging_desc.CPUAccessFlags     = D3D11_CPU_ACCESS_READ;
    staging_desc.BindFlags          = 0;
    staging_desc.MiscFlags          = 0;

    hr = ID3D11Device_CreateTexture2D(ctx->device, &staging_desc, NULL, &ctx->staging);
    if (FAILED(hr)) {
        fprintf(stderr, "capture_win: CreateTexture2D(staging) failed: 0x%08lx\n", (unsigned long)hr);
        goto fail;
    }

    /* Allocate persistent BGRA buffer */
    ctx->buffer_size = (size_t)ctx->width * ctx->height * 4;
    ctx->buffer = malloc(ctx->buffer_size);
    if (!ctx->buffer) {
        perror("capture_win: malloc");
        goto fail;
    }

    fprintf(stderr, "capture_win: %dx%d (DXGI Desktop Duplication)\n",
            ctx->width, ctx->height);
    return ctx;

fail:
    capture_free(ctx);
    return NULL;
}

int capture_width(const capture_ctx_t *ctx)  { return ctx->width;  }
int capture_height(const capture_ctx_t *ctx) { return ctx->height; }

const uint8_t *capture_grab(capture_ctx_t *ctx)
{
    HRESULT hr;
    IDXGIResource *frame_resource = NULL;
    DXGI_OUTDUPL_FRAME_INFO frame_info;

    hr = IDXGIOutputDuplication_AcquireNextFrame(ctx->duplication, 100, &frame_info, &frame_resource);

    if (hr == DXGI_ERROR_WAIT_TIMEOUT) {
        /* No new frame — return previous buffer contents */
        return ctx->buffer;
    }

    if (hr == DXGI_ERROR_ACCESS_LOST) {
        /* Desktop mode changed or another app took over — caller should retry init */
        fprintf(stderr, "capture_win: access lost (desktop mode change?)\n");
        return NULL;
    }

    if (FAILED(hr)) {
        fprintf(stderr, "capture_win: AcquireNextFrame failed: 0x%08lx\n", (unsigned long)hr);
        return NULL;
    }

    /* Get the GPU texture from the acquired frame */
    static const GUID local_IID_ID3D11Texture2D =
        {0x6f15aaf2,0xd208,0x4e89,{0x9a,0xb4,0x48,0x95,0x35,0xd3,0x4f,0x9c}};

    ID3D11Texture2D *frame_texture = NULL;
    hr = IDXGIResource_QueryInterface(frame_resource, &local_IID_ID3D11Texture2D, (void **)&frame_texture);
    IDXGIResource_Release(frame_resource);

    if (FAILED(hr)) {
        fprintf(stderr, "capture_win: QueryInterface(ID3D11Texture2D) failed: 0x%08lx\n", (unsigned long)hr);
        IDXGIOutputDuplication_ReleaseFrame(ctx->duplication);
        return NULL;
    }

    /* Copy GPU texture -> staging texture (CPU-readable) */
    ID3D11DeviceContext_CopyResource(ctx->context,
                                     (ID3D11Resource *)ctx->staging,
                                     (ID3D11Resource *)frame_texture);
    ID3D11Texture2D_Release(frame_texture);

    /* Map staging texture to read pixel data */
    D3D11_MAPPED_SUBRESOURCE mapped;
    hr = ID3D11DeviceContext_Map(ctx->context,
                                (ID3D11Resource *)ctx->staging,
                                0, D3D11_MAP_READ, 0, &mapped);
    if (FAILED(hr)) {
        fprintf(stderr, "capture_win: Map(staging) failed: 0x%08lx\n", (unsigned long)hr);
        IDXGIOutputDuplication_ReleaseFrame(ctx->duplication);
        return NULL;
    }

    /* Copy pixel data — handle row padding (stride != width*4) */
    size_t dest_stride = (size_t)ctx->width * 4;
    if ((size_t)mapped.RowPitch == dest_stride) {
        memcpy(ctx->buffer, mapped.pData, dest_stride * ctx->height);
    } else {
        for (int y = 0; y < ctx->height; y++) {
            memcpy(ctx->buffer + y * dest_stride,
                   (uint8_t *)mapped.pData + y * mapped.RowPitch,
                   dest_stride);
        }
    }

    ID3D11DeviceContext_Unmap(ctx->context,
                             (ID3D11Resource *)ctx->staging, 0);
    IDXGIOutputDuplication_ReleaseFrame(ctx->duplication);

    return ctx->buffer;
}

void capture_free(capture_ctx_t *ctx)
{
    if (!ctx)
        return;

    /* Release COM objects in reverse creation order */
    if (ctx->staging)
        ID3D11Texture2D_Release(ctx->staging);
    if (ctx->duplication)
        IDXGIOutputDuplication_Release(ctx->duplication);
    if (ctx->context)
        ID3D11DeviceContext_Release(ctx->context);
    if (ctx->device)
        ID3D11Device_Release(ctx->device);

    free(ctx->buffer);
    free(ctx);
}
