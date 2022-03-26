import {Event} from '../Event';
import {addAction, World, describeUser} from '../World';
import {PriceOracleProxy} from '../Contract/PriceOracleProxy';
import {buildPriceOracleProxy} from '../Builder/PriceOracleProxyBuilder';
import {invoke} from '../Invokation';
import {
  getAddressV,
  getEventV,
  getExpNumberV,
  getNumberV,
  getStringV
} from '../CoreValue';
import {
  AddressV,
  EventV,
  NumberV,
  ExpNumberV,
  StringV
} from '../Value';
import {Arg, Command, processCommandEvent, View} from '../Command';
import {getPriceOracleProxy} from '../ContractLookup';
import {verify} from '../Verify';
import { encodedNumber } from '../Encoding';

async function genPriceOracleProxy(world: World, from: string, params: Event): Promise<World> {
  let priceOracleProxy;
  let invokation;

  ({world, priceOracleProxy, invokation} = await buildPriceOracleProxy(world, from, params));

  world = addAction(
    world,
    `Deployed PriceOracleProxy to address ${priceOracleProxy._address}`,
    invokation
  );

  return world;
}

async function verifyPriceOracleProxy(world: World, priceOracleProxy: PriceOracleProxy, apiKey: string, contractName: string): Promise<World> {
  if (world.isLocalNetwork()) {
    world.printer.printLine(`Politely declining to verify on local network: ${world.network}.`);
  } else {
    await verify(world, apiKey, "PriceOracleProxy", contractName, priceOracleProxy._address);
  }

  return world;
}

/*async function setDirectPrice(world: World, from: string, priceOracleProxy: PriceOracleProxy, asset: string, amount: NumberV): Promise<World> {
  return addAction(
    world,
    `Set price oracle price for ${asset} to ${amount.show()}`,
    await invoke(world, priceOracleProxy.methods.setDirectPrice(asset, amount.encode()), from)
  );
}*/
async function setDirectPrice(world: World, from: string, priceOracleProxy: PriceOracleProxy, asset: string, amount: NumberV): Promise<World> {
  let invokation = await invoke(world, priceOracleProxy.methods.setDirectPrice(asset, amount.encode()), from);

  world = addAction(
      world,
      `Called add PPIE address ${asset} to ${amount.show()} as ${describeUser(world, from)}`,
      invokation
  );

  return world;
}

export function priceOracleProxyCommands() {
  return [
    new Command<{params: EventV}>(`
        #### Deploy

        * "Deploy ...params" - Generates a new price oracle proxy
          * E.g. "PriceOracleProxy Deploy (Unitroller Address) (PriceOracle Address) (pEther Address)"
      `,
      "Deploy",
      [
        new Arg("params", getEventV, {variadic: true})
      ],
      (world, from, {params}) => genPriceOracleProxy(world, from, params.val)
    ),

    new Command<{priceOracleProxy: PriceOracleProxy, asset: AddressV, amount: NumberV}>(`
        #### SetDirectPrice

        * "SetDirectPrice <Address> <Amount>" - Sets the per-ether price for the given pToken
          * E.g. "PriceOracle SetDirectPrice (Address Zero) 1.0"
      `,
      "SetDirectPrice",
      [
        new Arg("priceOracleProxy", getPriceOracleProxy, {implicit: true}),
        new Arg("asset", getAddressV),
        new Arg("amount", getExpNumberV)
      ],
      (world, from, {priceOracleProxy, asset, amount}) => setDirectPrice(world, from, priceOracleProxy, asset.val, amount)
    ),

    new View<{priceOracleProxy: PriceOracleProxy, apiKey: StringV, contractName: StringV}>(`
        #### Verify

        * "Verify apiKey:<String> contractName:<String>=PriceOracleProxy" - Verifies PriceOracleProxy in Etherscan
          * E.g. "PriceOracleProxy Verify "myApiKey"
      `,
      "Verify",
      [
        new Arg("priceOracleProxy", getPriceOracleProxy, {implicit: true}),
        new Arg("apiKey", getStringV),
        new Arg("contractName", getStringV, {default: new StringV("PriceOracleProxy")})
      ],
      (world, {priceOracleProxy, apiKey, contractName}) => verifyPriceOracleProxy(world, priceOracleProxy, apiKey.val, contractName.val)
    ),
  ];
}

export async function processPriceOracleProxyEvent(world: World, event: Event, from: string | null): Promise<World> {
  return await processCommandEvent<any>("PriceOracleProxy", priceOracleProxyCommands(), world, event, from);
}
