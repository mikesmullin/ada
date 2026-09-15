import { mcpResultToProviderContent, mcpResultToText, modelSupportsImages } from 'angela';

// Browser tools must use the same multimodal conversion as Angela's MCP tools.
// Throw MCP failures so AGL records an error, rather than a successful string.
export function browserResult(result, model) {
  if (result?.isError) {
    const code = result.structuredContent?.response?.data?.code || 'BROWSER_ERROR';
    throw Object.assign(new Error(`${code}: ${mcpResultToText(result) || 'Browser tool failed'}`), { code });
  }
  return mcpResultToProviderContent(result, { supportsImages: modelSupportsImages(model) });
}
