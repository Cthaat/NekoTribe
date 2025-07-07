import bcrypt from 'bcrypt';

export default defineEventHandler(async (event) => {
  const body = await readBody<registerPayload>(event)
  if (!body) {
    
  }
});