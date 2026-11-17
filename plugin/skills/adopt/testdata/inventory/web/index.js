import { greet } from './lib/greet.js';
const util = require('./lib/util.js');
const gone = require('./missing.js');

console.log(greet(util.name), gone);
