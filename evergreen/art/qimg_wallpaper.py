#!/usr/bin/env python3
"""Generate Evergreen sleep-screen wallpapers with Qwen-Image 2.1 on vengeance's
ComfyUI (:8188), text-to-image. Runs ON vengeance; stdlib only.

  python3 qimg_wallpaper.py OUTDIR N "subject"

Same model files and sampler settings as the book-documentary pipeline
(25 steps, cfg 1, euler/simple, fresh random seed per image).
"""
import json, os, random, sys, time, urllib.request

HOST = 'http://127.0.0.1:8188'
W, H = 1248, 1664   # 3:4 portrait, multiples of 32; cropped to the Kindle's 1236x1648 later
STYLE = ('Minimalist black ink line drawing with soft light-gray wash shading, like a gentle children\'s '
         'picture-book illustration, clean confident lines, high contrast, on a pure plain white background, '
         'lots of empty white space around the subject, calm and peaceful mood. Grayscale only. '
         'No text, no letters, no numbers, no signature, no border, no frame.')
NEG = 'text, letters, words, numbers, watermark, signature, frame, border, color, busy background, clutter, photo, 3d render, blurry'


def api(path, data=None, timeout=60):
    req = urllib.request.Request(HOST + path, data=json.dumps(data).encode() if data is not None else None,
                                 headers={'Content-Type': 'application/json'})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read())


def graph(prompt, seed, prefix):
    return {
        '1': {'class_type': 'UNETLoader', 'inputs': {'unet_name': 'qwen_image_2.1_bf16.safetensors', 'weight_dtype': 'default'}},
        '2': {'class_type': 'CLIPLoader', 'inputs': {'clip_name': 'qwen3vl_8b_int8_convrot.safetensors', 'type': 'qwen_image', 'device': 'default'}},
        '3': {'class_type': 'VAELoader', 'inputs': {'vae_name': 'qwen_image_2.1_vae_bf16.safetensors'}},
        '4': {'class_type': 'TextEncodeQwenImage21', 'inputs': {'clip': ['2', 0], 'prompt': prompt, 'negative_prompt': NEG, 'resolution': 1024}},
        '5': {'class_type': 'EmptyLatentImage', 'inputs': {'width': W, 'height': H, 'batch_size': 1}},
        '6': {'class_type': 'KSampler', 'inputs': {'model': ['1', 0], 'seed': seed, 'steps': 25, 'cfg': 1.0, 'sampler_name': 'euler',
                                                   'scheduler': 'simple', 'positive': ['4', 0], 'negative': ['4', 1], 'latent_image': ['5', 0], 'denoise': 1.0}},
        '7': {'class_type': 'VAEDecode', 'inputs': {'samples': ['6', 0], 'vae': ['3', 0]}},
        '8': {'class_type': 'SaveImage', 'inputs': {'images': ['7', 0], 'filename_prefix': prefix}},
    }


def main():
    out, n, subject = sys.argv[1], int(sys.argv[2]), sys.argv[3]
    os.makedirs(out, exist_ok=True)
    prompt = f'{subject} {STYLE}'
    for i in range(n):
        seed = random.SystemRandom().randrange(1, 2**48)
        pid = api('/prompt', {'prompt': graph(prompt, seed, f'evergreen_wall_{i}'), 'client_id': 'evergreen'})['prompt_id']
        t0 = time.time()
        while time.time() - t0 < 900:
            h = api(f'/history/{pid}')
            if pid in h:
                img = h[pid]['outputs']['8']['images'][0]
                q = f"filename={img['filename']}&subfolder={img['subfolder']}&type={img['type']}"
                with urllib.request.urlopen(f'{HOST}/view?{q}', timeout=120) as r:
                    open(os.path.join(out, f'dog_{i}.png'), 'wb').write(r.read())
                print(f'done dog_{i} seed={seed} {time.time() - t0:.0f}s', flush=True)
                break
            time.sleep(2)
        else:
            print(f'FAIL dog_{i} timeout', flush=True)


if __name__ == '__main__':
    main()
