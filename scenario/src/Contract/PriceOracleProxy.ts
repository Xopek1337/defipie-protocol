import {Contract} from '../Contract';
import {Callable, Sendable} from '../Invokation';
import {encodedNumber} from '../Encoding';

interface PriceOracleProxyMethods {
  getUnderlyingPrice(asset: string): Callable<number>
  implementaion(): Callable<string>;
  setSaiPrice(amount: encodedNumber): Sendable<number>
}

export interface PriceOracleProxy extends Contract {
  methods: PriceOracleProxyMethods
}
