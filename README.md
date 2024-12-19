# sparse_array

Noir library that implements efficient sparse arrays, both constant (SparseArray) and mutable (MutSparseArray)

## Noir version compatibility

This library is tested with all Noir stable releases from v0.36.0.

## Benchmarks

TODO

## Installation

In your _Nargo.toml_ file, add the version of this library you would like to install under dependency:

```
[dependencies]
sparse_array = { tag = "v0.1.0", git = "https://github.com/noir-lang/sparse_array" }
```

## `sparse_array`

### Usage

```rust
use dep::sparse_array::{SparseArray, MutSparseArray}

// a sparse array of size 10,000 with 10 nonzero values
fn example_sparse_array(nonzero_indices: [Field; 10], nonzero_values: [Field; 10]) {
    let sparse_array_size = 10000;
    let array: SparseArray<10, Field> = SparseArray::create(nonzero_indices, nonzero_values, sparse_array_size);

    assert(array.get(999) == 12345);
}

// a mutable sparse array that can contain up to 10 nonzero values
fn example_mut_sparse_array(initial_nonzero_indices: [Field; 9], initial_nonzero_values: [Field; 9]) {
    let sparse_array_size = 10000;
    let mut array: MutSparseArray<10, Field> = MutSparseArray::create(nonzero_indices, nonzero_values, sparse_array_size);

    // update element 1234 to contain value 9999
    array.set(1234, 9999);

    // error, array can only contain 10 nonzero values
    array.ser(10, 888);
}
```

# Costs

Constructing arrays is proportional to the number of nonzero entries in the array and very small ~10 gates per element (plus the cost of initializing range tables if not already done so)

Reading from `SparseArray` is 14.5 gates
Reading and writing to `MutSparseArray` is ~30 gates
