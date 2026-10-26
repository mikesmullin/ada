import { mcpResultToProviderContent, mcpResultToText, modelSupportsImages } from 'angela';

// Browser tools must use the same multimodal conversion as Angela's MCP tools.
// Throw MCP failures so AGL records an error, rather than a successful string.
// supportsImagesOverride: explicit harness flag (config images.vision) wins;
// otherwise fall back to the model-label heuristic.
export function browserResult(result, model, supportsImagesOverride) {
  if (result?.isError) {
    const code = result.structuredContent?.response?.data?.code || 'BROWSER_ERROR';
    throw Object.assign(new Error(`${code}: ${mcpResultToText(result) || 'Browser tool failed'}`), { code });
  }
  const supportsImages =
    typeof supportsImagesOverride === 'boolean'
      ? supportsImagesOverride
      : modelSupportsImages(model);
  return mcpResultToProviderContent(result, { supportsImages });
}
