// Configuración de Firebase
const firebaseConfig = {
    apiKey: "AIzaSyDSPfuNhHxO3ILg_BO2uK6jmiTQvxxdrss",
    authDomain: "comparador-de-precios-ae4b4.firebaseapp.com",
    databaseURL: "https://comparador-de-precios-ae4b4-default-rtdb.firebaseio.com",
    projectId: "comparador-de-precios-ae4b4",
    storageBucket: "comparador-de-precios-ae4b4.firebasestorage.app",
    messagingSenderId: "764983752712",
    appId: "1:764983752712:web:9ceed2bc4cf7f76adaf9bd",
    measurementId: "G-WC3YSRPJ3P"
};

// Inicializar Firebase
firebase.initializeApp(firebaseConfig);
const db = firebase.database();

let map;
let products = [];

// Inicializar el mapa
function initMap() {
    if (navigator.geolocation) {
        navigator.geolocation.getCurrentPosition(
            (position) => {
                const userLocation = {
                    lat: position.coords.latitude,
                    lng: position.coords.longitude
                };

                map = new google.maps.Map(document.getElementById("map"), {
                    center: userLocation,
                    zoom: 14
                });

                new google.maps.Marker({
                    position: userLocation,
                    map: map,
                    title: "Tu ubicación"
                });
            },
            () => {
                alert("No se pudo obtener la ubicación.");
            }
        );
    } else {
        alert("Geolocalización no es soportada por este navegador.");
    }
}

// Función para agregar un producto
function addProduct() {
  const productName = document.getElementById("productName").value;
  // ... (resto de tu código)

  // Guardar en Firebase
  const productRef = db.ref('products').push();
  productRef.set(productData)
    .then(() => {
      alert("Producto agregado exitosamente.");
      // Aquí puedes agregar lógica adicional, como actualizar la lista de productos en la interfaz
    })
    .catch((error) => {
      console.error('Error al guardar el producto:', error);
      alert('Ocurrió un error al guardar el producto. Por favor, inténtalo de nuevo.');
    });
}

    if (productName && !isNaN(productPrice) && storeLocation && productImage) {
        const productData = {
            name: productName,
            price: productPrice,
            store: storeLocation,
            image: URL.createObjectURL(productImage),
            location: map.getCenter() 
        };

        // Guardar en Firebase
        const productRef = db.ref('products/' + Date.now());
        productRef.set(productData);

        products.push(productData);
        alert("Producto agregado exitosamente.");
    } else {
        alert("Por favor, completa todos los campos.");
    }
}

// Función para buscar el mejor precio
function searchBestPrice() {
    const searchProductName = document.getElementById("searchProductName").value.toLowerCase();

    let bestPrice = Infinity;
    let bestProduct = null;

    products.forEach(product => {
        if (product.name.toLowerCase() === searchProductName && product.price < bestPrice) {
            bestPrice = product.price;
            bestProduct = product;
        }
    });

    if (bestProduct) {
        document.getElementById("bestStore").textContent = bestProduct.store;
        document.getElementById("bestPrice").textContent = bestPrice.toFixed(2);
        document.getElementById("bestLocation").textContent = `${bestProduct.location.lat}, ${bestProduct.location.lng}`;
        document.getElementById("recommendationBox").style.display = "block";
    } else {
        alert("Producto no encontrado.");
    }
}
