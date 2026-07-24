mod mut_sparse_array;
use ::sort::sort_advanced;

unconstrained fn __sort(lhs: u32, rhs: u32) -> bool {
    //  lhs.lt(rhs)
    lhs < rhs
}

fn assert_sorted(lhs: u32, rhs: u32) {
    assert(lhs < rhs);
}

/**
 * @brief shared constructor logic for SparseArray and MutSparseArrayBase:
 *        sort `input_keys`, write them into `keys[1..M+1]` with 0 and `maximum`
 *        as start/endpoints, and place each input value at its key's sorted slot
 *        (keys[i] maps to values[i+1]; values[0] stays the default empty value)
 **/
fn insert_sorted_keys_and_values<T, let M: u32, let K: u32, let V: u32>(
    input_keys: [u32; M],
    input_values: [T; M],
    maximum: u32,
    keys: &mut [u32; K],
    values: &mut [T; V],
)
where
    T: std::default::Default,
{
    // for any valid index, we want to ensure the following is satified:
    // keys[X] <= index <= keys[X+1]
    // this requires us to sort the keys, and insert a startpoint and endpoint
    let sorted_keys = sort_advanced(input_keys, __sort, assert_sorted);

    // insert start and endpoints
    keys[0] = 0;
    for i in 0..M {
        keys[i + 1] = sorted_keys.sorted[i];
    }
    keys[M + 1] = maximum;

    // sort_indices[i] is the sorted position of input key i, so write each
    // input value to its key's sorted slot
    for i in 0..M {
        values[sorted_keys.sort_indices[i] + 2] = input_values[i];
    }

    // insert values that map to our key start and endpoints
    // if input_keys[0] = 0 then values[1] must equal input_values[0], so some
    // conditional logic is required (same for input_keys[M-1])
    let mut initial_value = T::default();
    if (input_keys[0] == 0) {
        initial_value = input_values[0];
    }
    let mut final_value = T::default();
    if (input_keys[M - 1] == maximum) {
        final_value = input_values[M - 1];
    }
    values[1] = initial_value;
    values[M + 2] = final_value;

    // perform boundary checks!
    // because the keys are sorted, checking the largest key does not exceed
    // `maximum` validates every key
    assert(maximum >= sorted_keys.sorted[M - 1]);
}

/**
 * @brief MutSparseArray, a sparse array of configurable size with `N` nonzero entries.
 *        Can be read from and written into
 *
 * @param keys is size N+2 because we want to always ensure that,
 *        for any valid index, there is some X where `keys[X] <= index <= keys[X+1]`
 *        when constructing, we will set keys[0] = 0, and keys[N-1] = maximum - 1
 * @param values is size N+3 because of the following:
 *        1. keys[i] maps to values[i+1]
 *        2. values[0] is an empty object. when calling `get(idx)`, if `idx` is not in `keys` we will return `values[0]`
 **/
struct MutSparseArrayBase<let N: u32, T, ComparisonFuncs> {
    values: [T; N + 3],
    keys: [u32; N + 2],
    linked_keys: [u32; N + 2],
    tail_ptr: u32,
    maximum: u32,
}

struct U32RangeTraits {}

pub struct MutSparseArray<let N: u32, T> {
    inner: MutSparseArrayBase<N, T, U32RangeTraits>,
}
/**
 * @brief SparseArray, stores a sparse array of up to size 2^32 with `N` nonzero entries
 *        SparseArray is constant i.e. values canot be inserted after creation.
 *        See MutSparseArray for a mutable version (a bit more expensive)
 * @param keys is size N+2 because we want to always ensure that,
 *        for any valid index, there is some X where `keys[X] <= index <= keys[X+1]`
 *        when constructing, we will set keys[0] = 0, and keys[N-1] = maximum - 1
 * @param values is size N+3 because of the following:
 *        1. keys[i] maps to values[i+1]
 *        2. values[0] is an empty object. when calling `get(idx)`, if `idx` is not in `keys` we will return `values[0]`
 **/
pub struct SparseArray<let N: u32, T> {
    keys: [u32; N + 2],
    values: [T; N + 3],
    maximum: u32, // can be up to 2^32 - 1
}
impl<let N: u32, T> SparseArray<N, T>
where
    T: std::default::Default,
{

    /**
     * @brief construct a SparseArray
     **/
    pub(crate) fn create(_keys: [u32; N], _values: [T; N], size: u32) -> Self {
        assert(size >= 1);
        let _maximum = size - 1;
        let mut r: Self =
            SparseArray { keys: [0; N + 2], values: [T::default(); N + 3], maximum: _maximum };

        insert_sorted_keys_and_values(_keys, _values, _maximum, &mut r.keys, &mut r.values);
        r
    }

    /**
     * @brief determine whether `target` is present in `self.keys`
     * @details if `found == false`, `self.keys[found_index] < target < self.keys[found_index + 1]`
     **/
    unconstrained fn search_for_key(self, target: u32) -> (bool, u32) {
        let mut found = false;
        let mut found_index: u32 = 0;
        let mut previous_less_than_or_equal_to_target = false;
        for i in 0..N + 2 {
            // if target = 0xffffffff we need to be able to add 1 here, so use u64
            let current_less_than_or_equal_to_target = self.keys[i] as u64 <= target as u64;
            if (self.keys[i] == target) {
                found = true;
                found_index = i;
                break;
            }
            if (previous_less_than_or_equal_to_target & !current_less_than_or_equal_to_target) {
                found_index = i - 1;
                break;
            }
            previous_less_than_or_equal_to_target = current_less_than_or_equal_to_target;
        }
        (found, found_index)
    }

    /**
     * @brief return element `idx` from the sparse array
     * @details cost is 14.5 gates per lookup
     **/
    fn get(self, idx: u32) -> T {
        let (found, found_index) = unsafe { self.search_for_key(idx) };

        // OK! So we have the following cases to check
        // 1. if `found` then `self.keys[found_index] == idx`
        // 2. if `!found` then `self.keys[found_index] < idx < self.keys[found_index + 1]
        // how do we simplify these checks?
        // case 1 can be converted to `self.keys[found_index] <= idx <= self.keys[found_index]
        // case 2 can be modified to  `self.keys[found_index] + 1 <= idx <= self.keys[found_index + 1] - 1
        // combine the two into the following single statement:
        // `self.keys[found_index] + 1 - found <= idx <= self.keys[found_index + 1 - found] - 1 + found
        let lhs = self.keys[found_index];
        let rhs = self.keys[found_index + 1 - found as u32];
        assert(lhs + 1 - found as u32 <= idx);
        assert(idx <= rhs + found as u32 - 1);

        // self.keys[i] maps to self.values[i+1]
        // however...if we did not find a non-sparse entry, we want to return self.values[0] (the default value)
        let value_index = (found_index + 1) * found as u32;
        self.values[value_index]
    }
}

mod test {

    use super::SparseArray;
    #[test]
    fn test_sparse_lookup() {
        let example = SparseArray::create([1, 99, 7, 5], [123, 101112, 789, 456], 100);

        assert(example.get(1) == 123);
        assert(example.get(5) == 456);
        assert(example.get(7) == 789);
        assert(example.get(99) == 101112);

        for i in 0..100 {
            if ((i != 1) & (i != 5) & (i != 7) & (i != 99)) {
                assert(example.get(i) == 0);
            }
        }
    }

    #[test]
    fn test_sparse_lookup_boundary_cases() {
        // what about when keys[0] = 0 and keys[N-1] = 2^32 - 1?
        let example = SparseArray::create(
            [0, 99999, 7, 0xfffffffe],
            [123, 101112, 789, 456],
            0xffffffff,
        );

        assert(example.get(0) == 123);
        assert(example.get(99999) == 101112);
        assert(example.get(7) == 789);
        assert(example.get(0xfffffffe) == 456);
        assert(example.get(0xfffffffd) == 0);
    }

    #[test(should_fail)]
    fn test_sparse_lookup_overflow() {
        let example = SparseArray::create([1, 5, 7, 99999], [123, 456, 789, 101112], 100000);

        assert(example.get(100000) == 0);
    }

    /**
    #[test(should_fail_with = "call to assert_max_bit_size")]
    fn test_sparse_lookup_boundary_case_overflow() {
        let example =
            SparseArray::create([0, 5, 7, 0xffffffff], [123, 456, 789, 101112], 0x100000000);

        assert(example.get(0x100000000) == 0);
    }
    **/
    #[test(should_fail)]
    fn test_sparse_lookup_key_exceeds_maximum() {
        let example =
            SparseArray::create([0, 5, 7, 0xffffffff], [123, 456, 789, 101112], 0xffffffff);
        assert(example.maximum == 0xffffffff);
    }

    // Regression test for https://github.com/noir-lang/noir-library-claude/issues/6
    // The keys [3, 1, 2] sort via a 3-cycle permutation, so `sort_indices` differs
    // from its inverse. `create` must use the inverse map when populating values,
    // otherwise `get(key)` returns a different key's value.
    #[test]
    fn test_sparse_lookup_non_involution_key_order() {
        let example = SparseArray::create([3, 1, 2], [30, 10, 20], 100);

        assert(example.get(1) == 10);
        assert(example.get(2) == 20);
        assert(example.get(3) == 30);
    }

    #[test]
    fn test_sparse_lookup_u32() {
        let example = SparseArray::create(
            [1, 99, 7, 5],
            [123 as u32, 101112 as u32, 789 as u32, 456 as u32],
            100,
        );

        assert(example.get(1) == 123);
        assert(example.get(5) == 456);
        assert(example.get(7) == 789);
        assert(example.get(99) == 101112);

        for i in 0..100 {
            if ((i != 1) & (i != 5) & (i != 7) & (i != 99)) {
                assert(example.get(i) == 0);
            }
        }
    }

    struct F {
        foo: [Field; 3],
    }
    impl std::cmp::Eq for F {
        fn eq(self, other: Self) -> bool {
            self.foo == other.foo
        }
    }

    impl std::default::Default for F {
        fn default() -> Self {
            F { foo: [0; 3] }
        }
    }

    #[test]
    fn test_sparse_lookup_struct() {
        let values = [
            F { foo: [1, 2, 3] },
            F { foo: [4, 5, 6] },
            F { foo: [7, 8, 9] },
            F { foo: [10, 11, 12] },
        ];
        let example = SparseArray::create([1, 99, 7, 5], values, 100000);

        assert(example.get(1) == values[0]);
        assert(example.get(5) == values[3]);
        assert(example.get(7) == values[2]);
        assert(example.get(99) == values[1]);
        for i in 0..100 {
            if ((i != 1) & (i != 5) & (i != 7) & (i != 99)) {
                assert(example.get(i) == F::default());
            }
        }
    }
}
