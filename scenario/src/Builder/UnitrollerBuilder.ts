import {Event} from '../Event';
import {World} from '../World';
import {Unitroller} from '../Contract/Unitroller';
import {Invokation} from '../Invokation';
import {
    getAddressV,
} from '../CoreValue';
import {
    AddressV,
} from '../Value';
import {Arg, Fetcher, getFetcherValue} from '../Command';
import {storeAndSaveContract} from '../Networks';
import {getContract} from '../Contract';

const UnitrollerContract = getContract("Unitroller");

export interface UnitrollerData {
  invokation: Invokation<Unitroller>,
  description: string,
  address?: string
}

export async function buildUnitroller(world: World, from: string, event: Event): Promise<{world: World, unitroller: Unitroller, unitrollerData: UnitrollerData}> {
  const fetchers = [
    new Fetcher<{
        registryProxy: AddressV;
    }, UnitrollerData>(`
        #### Unitroller

        * "" - The Upgradable Controller
        * " registryProxy:<String> " - The Unitroller contract
          * E.g. "Unitroller Deploy (RegistryProxy Address)"
      `,
      "Unitroller",
      [
          new Arg('registryProxy', getAddressV),
      ],
      async (world, {
          registryProxy
      }) => {
        return {
          invokation: await UnitrollerContract.deploy<Unitroller>(world, from, [
              registryProxy.val
          ]),
          description: "Unitroller"
        };
      },
      {catchall: true}
    )
  ];

  let unitrollerData = await getFetcherValue<any, UnitrollerData>("DeployUnitroller", fetchers, world, event);
  let invokation = unitrollerData.invokation;
  delete unitrollerData.invokation;

  if (invokation.error) {
    throw invokation.error;
  }
  const unitroller = invokation.value!;
  unitrollerData.address = unitroller._address;

  world = await storeAndSaveContract(
    world,
    unitroller,
    'Unitroller',
    invokation,
    [
      { index: ['Unitroller'], data: unitrollerData }
    ]
  );

  return {world, unitroller, unitrollerData};
}
