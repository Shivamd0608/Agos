import { buildApp } from "./app.js";

const app = buildApp();

const start = async () => {
  try {
    await app.listen({ port: Number(process.env.PORT ?? 3001), host: "0.0.0.0" });
    console.log(`Agos Facilitator running on :${process.env.PORT ?? 3001}`);
  } catch (err) {
    app.log.error(err);
    process.exit(1);
  }
};

start();
