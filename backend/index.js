const express = require('express');
const http = require('http');
const { Server } = require('socket.io');
const cors = require('cors');

const app = express();
const server = http.createServer(app);
const io = new Server(server, {
  cors: {
    origin: '*',
    methods: ['GET', 'POST'],
  },
});

app.use(cors());
app.use(express.json());

const PORT = 3001;

// Define the 10 stocks and their baseline prices
const baseStocks = [
  { ticker: 'RELIANCE', base: 2450.0 },
  { ticker: 'TCS', base: 3400.0 },
  { ticker: 'INFY', base: 1550.0 },
  { ticker: 'HDFCBANK', base: 1600.0 },
  { ticker: 'ICICIBANK', base: 950.0 },
  { ticker: 'TATAMOTORS', base: 620.0 },
  { ticker: 'SBIN', base: 580.0 },
  { ticker: 'BHARTIAIRTEL', base: 880.0 },
  { ticker: 'ITC', base: 450.0 },
  { ticker: 'WIPRO', base: 410.0 },
];

const sources = ['nse', 'bse', 'yahoo', 'broker'];

// In-memory store for current prices
const stockGrid = {};

// Helper to get formatted local timestamp
function getTimestamp() {
  return new Date().toISOString();
}

// Initialize the grid with starting prices (with slight variance per source)
baseStocks.forEach((stock) => {
  stockGrid[stock.ticker] = {
    ticker: stock.ticker,
  };
  
  sources.forEach((source) => {
    // Variance between -0.1% and +0.1% on initial load
    const variance = 1 + (Math.random() * 0.002 - 0.001);
    const startPrice = parseFloat((stock.base * variance).toFixed(2));
    stockGrid[stock.ticker][source] = {
      price: startPrice,
      timestamp: getTimestamp(),
    };
  });
});

// REST Endpoint to fetch initial prices
app.get('/api/stocks', (req, res) => {
  const stockList = Object.values(stockGrid);
  res.json(stockList);
});

// WebSockets Connection
io.on('connection', (socket) => {
  console.log('Client connected to Stock Feed:', socket.id);
  
  socket.on('disconnect', () => {
    console.log('Client disconnected from Stock Feed:', socket.id);
  });
});

// Stock Feed Simulator Engine
// Triggers an update every 300ms on a random stock and a random source
setInterval(() => {
  // 1. Pick a random stock
  const randomStockIdx = Math.floor(Math.random() * baseStocks.length);
  const ticker = baseStocks[randomStockIdx].ticker;
  
  // 2. Pick a random source
  const randomSourceIdx = Math.floor(Math.random() * sources.length);
  const source = sources[randomSourceIdx];
  
  // 3. Calculate price change delta (between -0.15% and +0.15%)
  const currentVal = stockGrid[ticker][source].price;
  const changePercent = (Math.random() * 0.003 - 0.0015); // -0.15% to +0.15%
  let newVal = currentVal * (1 + changePercent);
  
  // Prevent stock price dropping to negative or zero
  if (newVal <= 0) {
    newVal = baseStocks[randomStockIdx].base * 0.5;
  }
  
  const finalPrice = parseFloat(newVal.toFixed(2));
  const nowTimestamp = getTimestamp();
  
  // Update internal memory
  stockGrid[ticker][source] = {
    price: finalPrice,
    timestamp: nowTimestamp,
  };
  
  // 4. Emit the update to all connected socket clients
  const updateData = {
    ticker,
    source,
    price: finalPrice,
    timestamp: nowTimestamp,
  };
  
  io.emit('stock-update', updateData);
}, 300); // 300ms frequency keeps the dashboard lively

server.listen(PORT, '0.0.0.0', () => {
  console.log(`Stock Price Aggregator backend running on port ${PORT}`);
});
