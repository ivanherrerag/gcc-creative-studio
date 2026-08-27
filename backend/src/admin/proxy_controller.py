# Copyright 2025 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

from fastapi import APIRouter, Request, Response
import httpx
import logging
from src.config.config_service import config_service

router = APIRouter(prefix="/api/security-proxy")
logger = logging.getLogger("security_proxy")

@router.post("/{path:path}")
async def loopback_proxy(path: str, request: Request):
    """
    A loopback security proxy that intercepts Vertex AI SDK calls.
    This allows for auditing, logging, and potentially filtering GenAI requests
    before they are forwarded to the actual Google Cloud endpoints.
    """
    # 1. Capture the payload for security auditing
    try:
        body = await request.json()
        logger.info(f"SECURITY AUDIT - Model Call: {path}")
        # In a real-world scenario, you could perform DLP scans or policy enforcement here.
    except Exception as e:
        logger.warning(f"Failed to parse request body for auditing: {e}")
        body = await request.body()
    
    # 2. Determine the target Google Cloud endpoint
    # Most Vertex AI calls are regional. Omni models are global.
    if "global" in path or "omni" in path.lower():
        google_url = f"https://aiplatform.googleapis.com/{path}"
    else:
        location = config_service.LOCATION
        google_url = f"https://{location}-aiplatform.googleapis.com/{path}"
    
    async with httpx.AsyncClient() as client:
        # We forward the body and the headers (which include the Auth token)
        # We MUST remove hop-by-hop headers so the target Google endpoint accepts the request.
        hop_by_hop_headers = {
            "host",
            "content-length",
            "connection",
            "keep-alive",
            "proxy-authenticate",
            "proxy-authorization",
            "te",
            "trailer",
            "transfer-encoding",
            "upgrade",
        }
        headers = {
            k: v for k, v in request.headers.items() 
            if k.lower() not in hop_by_hop_headers
        }
        
        try:
            response = await client.post(
                google_url,
                headers=headers,
                json=body if isinstance(body, dict) else None,
                content=body if not isinstance(body, dict) else None,
                timeout=60.0
            )
            
            # Return the exact response from Vertex back to the SDK
            # Remove content-encoding and content-length because httpx automatically
            # decompresses the body.
            response_headers = dict(response.headers)
            response_headers.pop("content-encoding", None)
            response_headers.pop("content-length", None)
            
            return Response(
                content=response.content,
                status_code=response.status_code,
                headers=response_headers
            )
        except Exception as e:
            logger.error(f"Proxy failed to forward request to {google_url}: {e}")
            return Response(
                content=str(e),
                status_code=500
            )
