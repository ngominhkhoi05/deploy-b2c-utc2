import io
import logging
from typing import List, Optional
from fastapi import FastAPI, File, UploadFile, HTTPException
from pydantic import BaseModel, HttpUrl
from PIL import Image
import requests
from sentence_transformers import SentenceTransformer

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
logger = logging.getLogger("image-embedding-service")

app = FastAPI(title="Image Embedding Service", version="1.0.0")

MODEL_NAME = "sentence-transformers/clip-ViT-B-32"
logger.info("Dang tai model %s...", MODEL_NAME)
model = SentenceTransformer(MODEL_NAME)
logger.info("Tai model %s thanh cong! San sang phuc vu.", MODEL_NAME)


class UrlRequest(BaseModel):
    url: str


class BatchUrlRequest(BaseModel):
    urls: List[str]


class BatchUrlItemResult(BaseModel):
    url: str
    success: bool
    vector: Optional[List[float]] = None
    error: Optional[str] = None


class BatchUrlResponse(BaseModel):
    results: List[BatchUrlItemResult]


@app.get("/health")
def health_check():
    return {"status": "UP", "model": MODEL_NAME, "dimension": 512}


@app.post("/embed-image")
async def embed_image(file: UploadFile = File(...)):
    """Trích xuất vector embedding 512 chiều từ file ảnh upload."""
    if not file.content_type.startswith("image/"):
        raise HTTPException(status_code=400, detail="File phai la dinh dang anh")

    try:
        contents = await file.read()
        image = Image.open(io.BytesIO(contents)).convert("RGB")
        # Normalize embeddings = True để tối ưu cho Cosine Distance
        embedding = model.encode(image, normalize_embeddings=True)
        return {
            "success": True,
            "dimension": len(embedding),
            "vector": embedding.tolist(),
        }
    except Exception as e:
        logger.error("Loi khi embed image file: %s", str(e), exc_info=True)
        raise HTTPException(status_code=500, detail=f"Khong the trich xuat vector: {str(e)}")


@app.post("/embed-url")
def embed_url(req: UrlRequest):
    """Trích xuất vector embedding 512 chiều từ link ảnh URL."""
    try:
        resp = requests.get(req.url, timeout=10, headers={"User-Agent": "FlashSale-ImageEmbedding/1.0"})
        resp.raise_for_status()
        image = Image.open(io.BytesIO(resp.content)).convert("RGB")
        embedding = model.encode(image, normalize_embeddings=True)
        return {
            "success": True,
            "dimension": len(embedding),
            "vector": embedding.tolist(),
        }
    except Exception as e:
        logger.error("Loi khi embed URL %s: %s", req.url, str(e))
        raise HTTPException(status_code=400, detail=f"Khong the tai hoac xu ly anh tu URL: {str(e)}")


@app.post("/embed-batch-urls", response_model=BatchUrlResponse)
def embed_batch_urls(req: BatchUrlRequest):
    """Trích xuất vector cho danh sách URLs (phục vụ Admin Reindex)."""
    results = []
    images_to_encode = []
    valid_indices = []

    for i, url in enumerate(req.urls):
        try:
            resp = requests.get(url, timeout=10, headers={"User-Agent": "FlashSale-ImageEmbedding/1.0"})
            resp.raise_for_status()
            img = Image.open(io.BytesIO(resp.content)).convert("RGB")
            images_to_encode.append(img)
            valid_indices.append(i)
            results.append(BatchUrlItemResult(url=url, success=True))
        except Exception as e:
            logger.warning("Loi tai anh tai URL %s: %s", url, str(e))
            results.append(BatchUrlItemResult(url=url, success=False, error=str(e)))

    if images_to_encode:
        embeddings = model.encode(images_to_encode, batch_size=16, normalize_embeddings=True)
        for idx, emb in zip(valid_indices, embeddings):
            results[idx].vector = emb.tolist()

    return BatchUrlResponse(results=results)
