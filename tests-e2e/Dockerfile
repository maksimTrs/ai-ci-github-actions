FROM mcr.microsoft.com/playwright:latest

WORKDIR /tests

COPY package*.json ./

RUN npm ci

COPY . .

CMD ["npx", "playwright", "test"] 