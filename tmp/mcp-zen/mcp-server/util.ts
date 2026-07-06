import * as net from "net";

export function isPortInUse(port: number): Promise<boolean> {
  return new Promise((resolve) => {
    const server = net.createServer();

    server.once("error", (err: NodeJS.ErrnoException) => {
      if (err.code === "EADDRINUSE") {
        resolve(true);
      } else {
        console.error("Error checking port:", err);
        resolve(false);
      }
    });

    server.once("listening", () => {
      server.close(() => {
        resolve(false);
      });
    });

    server.listen(port, "localhost");
  });
}
